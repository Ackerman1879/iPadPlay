import UIKit

final class ViewController: UIViewController {

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "iPadPlay"
        label.font = .systemFont(ofSize: 42, weight: .bold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.text = "Experimental CarPlay Receiver"
        label.font = .systemFont(ofSize: 20)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.text = "Receiver: Not Started"
        label.font = .monospacedSystemFont(ofSize: 16, weight: .medium)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let startButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Start Receiver", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground

        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        view.addSubview(statusLabel)
        view.addSubview(startButton)

        startButton.addTarget(
            self,
            action: #selector(startReceiver),
            for: .touchUpInside
        )

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.centerYAnchor.constraint(
                equalTo: view.centerYAnchor,
                constant: -100
            ),

            subtitleLabel.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor,
                constant: 12
            ),
            subtitleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            statusLabel.topAnchor.constraint(
                equalTo: subtitleLabel.bottomAnchor,
                constant: 40
            ),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            startButton.topAnchor.constraint(
                equalTo: statusLabel.bottomAnchor,
                constant: 32
            ),
            startButton.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    @objc
    private func startReceiver() {
        statusLabel.text = "Receiver: Starting..."
        startButton.isEnabled = false
    }
}