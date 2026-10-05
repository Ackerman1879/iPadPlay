import UIKit
import Network
import AVFoundation
import CoreMedia

final class CarPlayVideoView: UIView {
    var sendTouch: ((CGFloat, CGFloat, Bool) -> Void)?
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = false
        displayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func forward(_ touch: UITouch, down: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let point = touch.location(in: self)
        sendTouch?(min(1, max(0, point.x / bounds.width)), min(1, max(0, point.y / bounds.height)), down)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { if let touch = touches.first { forward(touch, down: true) } }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { if let touch = touches.first { forward(touch, down: true) } }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { if let touch = touches.first { forward(touch, down: false) } }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { if let touch = touches.first { forward(touch, down: false) } }
}

final class H264DisplayDecoder {
    private let layer: AVSampleBufferDisplayLayer
    private var format: CMVideoFormatDescription?
    private var nalLengthSize = 4

    init(layer: AVSampleBufferDisplayLayer) { self.layer = layer }

    func configure(_ configuration: Data) throws {
        let bytes = [UInt8](configuration)
        guard bytes.count >= 7, bytes[0] == 1 else { throw formatError("收到不支持的视频配置") }
        nalLengthSize = Int(bytes[4] & 3) + 1
        var index = 5
        let spsCount = Int(bytes[index] & 0x1f)
        index += 1
        var parameterSets: [Data] = []
        for _ in 0..<spsCount {
            guard index + 2 <= bytes.count else { throw formatError() }
            let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            index += 2
            guard index + length <= bytes.count else { throw formatError() }
            parameterSets.append(Data(bytes[index..<(index + length)]))
            index += length
        }
        guard index < bytes.count else { throw formatError() }
        let ppsCount = Int(bytes[index])
        index += 1
        for _ in 0..<ppsCount {
            guard index + 2 <= bytes.count else { throw formatError() }
            let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            index += 2
            guard index + length <= bytes.count else { throw formatError() }
            parameterSets.append(Data(bytes[index..<(index + length)]))
            index += length
        }
        guard parameterSets.count >= 2 else { throw formatError() }

        var description: CMFormatDescription?
        let status = parameterSets[0].withUnsafeBytes { spsBytes in
            parameterSets[1].withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [parameterSets[0].count, parameterSets[1].count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else { throw formatError() }
        format = description
        DispatchQueue.main.async { self.layer.flushAndRemoveImage() }
    }

    func display(_ packet: Data) throws {
        guard let format else { return }
        let sampleData = try normalizedNALUnits(packet)
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sampleData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { throw formatError() }
        status = sampleData.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: sampleData.count)
        }
        guard status == kCMBlockBufferNoErr else { throw formatError() }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = sampleData.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw formatError() }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary], let attachment = attachments.first {
            attachment[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        DispatchQueue.main.async {
            if self.layer.status == .failed { self.layer.flush() }
            self.layer.enqueue(sampleBuffer)
        }
    }

    private func normalizedNALUnits(_ data: Data) throws -> Data {
        guard nalLengthSize != 4 else { return data }
        let bytes = [UInt8](data)
        var index = 0
        var output = Data()
        while index + nalLengthSize <= bytes.count {
            var length = 0
            for _ in 0..<nalLengthSize { length = length << 8 | Int(bytes[index]); index += 1 }
            guard length > 0, index + length <= bytes.count else { throw formatError() }
            var bigEndian = UInt32(length).bigEndian
            withUnsafeBytes(of: &bigEndian) { output.append(contentsOf: $0) }
            output.append(contentsOf: bytes[index..<(index + length)])
            index += length
        }
        return output
    }

    private func formatError(_ message: String = "视频数据格式无效") -> NSError {
        NSError(domain: "iPadPlay", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

final class ViewController: UIViewController, NetServiceBrowserDelegate, NetServiceDelegate {
    private let statusLabel = UILabel()
    private let computerLabel = UILabel()
    private let hostField = UITextField()
    private let codeField = UITextField()
    private let connectButton = UIButton(type: .system)
    private let videoView = CarPlayVideoView()
    private var decoder: H264DisplayDecoder!
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var socket: URLSessionWebSocketTask?
    private var endpointPort = 18443

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        decoder = H264DisplayDecoder(layer: videoView.displayLayer)
        buildInterface()
        videoView.sendTouch = { [weak self] x, y, down in self?.sendTouch(x: x, y: y, down: down) }
        startDiscovery()
    }

    private func buildInterface() {
        let title = UILabel()
        title.text = "iPadPlay"
        title.font = .systemFont(ofSize: 32, weight: .bold)
        title.textAlignment = .center
        statusLabel.text = "正在查找运行WinPlay的电脑…"
        statusLabel.textAlignment = .center
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2
        computerLabel.text = "尚未发现电脑"
        computerLabel.textAlignment = .center
        computerLabel.font = .systemFont(ofSize: 17, weight: .medium)
        hostField.placeholder = "电脑IP地址（自动发现失败时填写）"
        hostField.borderStyle = .roundedRect
        hostField.autocapitalizationType = .none
        hostField.autocorrectionType = .no
        hostField.keyboardType = .numbersAndPunctuation
        codeField.placeholder = "WinPlay显示的六位连接码"
        codeField.borderStyle = .roundedRect
        codeField.keyboardType = .numberPad
        codeField.textContentType = .oneTimeCode
        connectButton.setTitle("连接电脑", for: .normal)
        connectButton.titleLabel?.font = .systemFont(ofSize: 19, weight: .semibold)
        connectButton.addTarget(self, action: #selector(connect), for: .touchUpInside)
        videoView.isHidden = true
        videoView.layer.cornerRadius = 14
        videoView.clipsToBounds = true

        let form = UIStackView(arrangedSubviews: [title, statusLabel, computerLabel, hostField, codeField, connectButton])
        form.axis = .vertical
        form.spacing = 14
        form.translatesAutoresizingMaskIntoConstraints = false
        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(form)
        view.addSubview(videoView)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            form.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 36),
            form.widthAnchor.constraint(equalToConstant: 360),
            videoView.leadingAnchor.constraint(equalTo: form.trailingAnchor, constant: 28),
            videoView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            videoView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            videoView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18)
        ])
    }

    private func startDiscovery() {
        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        browser.searchForServices(ofType: "_ipadplay._tcp.", inDomain: "local.")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")), sender.port > 0 else { return }
        DispatchQueue.main.async {
            self.hostField.text = host
            self.endpointPort = sender.port
            self.computerLabel.text = "已发现：\(sender.name)"
            self.statusLabel.text = "请输入WinPlay中的六位连接码"
        }
    }

    @objc private func connect() {
        view.endEditing(true)
        guard let host = hostField.text?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            statusLabel.text = "尚未发现电脑，请填写电脑IP地址"
            return
        }
        guard let code = codeField.text, code.count == 6, Int(code) != nil else {
            statusLabel.text = "请输入六位数字连接码"
            return
        }
        socket?.cancel(with: .goingAway, reason: nil)
        guard let url = URL(string: "ws://\(host):\(endpointPort)/stream") else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        statusLabel.text = "正在连接WinPlay…"
        let hello = try! JSONSerialization.data(withJSONObject: ["type": "hello", "code": code])
        task.send(.string(String(data: hello, encoding: .utf8)!)) { [weak self] error in
            if let error { DispatchQueue.main.async { self?.statusLabel.text = "连接失败：\(error.localizedDescription)" } }
        }
        receiveNext()
    }

    private func receiveNext() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async { self.statusLabel.text = "连接已断开：\(error.localizedDescription)" }
            case .success(let message):
                self.handle(message)
                self.receiveNext()
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            if let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = object["type"] as? String {
                DispatchQueue.main.async {
                    if type == "ready" {
                        self.statusLabel.text = "已连接，等待CarPlay画面"
                        self.videoView.isHidden = false
                    } else if type == "error" {
                        self.statusLabel.text = object["message"] as? String ?? "连接码错误"
                    }
                }
            }
        case .data(let data):
            guard let type = data.first else { return }
            let payload = data.dropFirst()
            do {
                if type == 1 {
                    try decoder.configure(Data(payload))
                    sendJSON(["type": "keyframe"])
                } else if type == 2 {
                    try decoder.display(Data(payload))
                }
            } catch {
                DispatchQueue.main.async { self.statusLabel.text = "视频解码失败：\(error.localizedDescription)" }
            }
        @unknown default:
            break
        }
    }

    private func sendTouch(x: CGFloat, y: CGFloat, down: Bool) {
        sendJSON(["type": "touch", "x": x, "y": y, "down": down])
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(text)) { _ in }
    }
}
