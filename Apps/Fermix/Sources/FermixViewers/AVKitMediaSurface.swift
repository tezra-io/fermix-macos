import AVKit
import AppKit
import FermixAppCore

/// AVKit's player view on the app's one player and, centred on the pane's
/// ground for while the tab does not hold the player, the tab's own Play: a
/// system push button at the large size, the shape every control beside it
/// takes.
@MainActor
final class AVKitMediaSurface: NSView, BrowserMediaSurface {
    var onPlay: (@MainActor () -> Void)?

    private let player: AppPlayer
    private let playerView = AVPlayerView()
    private let playButton = NSButton(title: ProductStrings[.mediaPlay], target: nil, action: nil)

    init(player: AppPlayer) {
        self.player = player
        super.init(frame: .zero)

        playerView.controlsStyle = .inline
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        playButton.imagePosition = .imageLeading
        playButton.controlSize = .large
        playButton.target = self
        playButton.action = #selector(playPressed)
        place()
        show(holding: false, playable: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("the media surface is built in code")
    }

    var view: NSView { self }

    func show(holding: Bool, playable: Bool) {
        playerView.player = holding ? player.avPlayer : nil
        playerView.isHidden = !holding
        playButton.isHidden = holding
        playButton.isEnabled = playable
    }

    @objc private func playPressed() {
        onPlay?()
    }

    private func place() {
        for subview in [playerView, playButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}
