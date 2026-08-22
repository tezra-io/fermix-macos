import AppKit
import Combine
import SwiftUI

/// The `NSStatusItem`, its glyph, and the panel under it.
///
/// The status item is the app: closing every window leaves this running. The
/// glyph is the approved template raster (so macOS tints it for the current
/// menu-bar appearance), the starting state pulses on a timer because an
/// `NSStatusItem` image is not something SwiftUI animates, and the attention
/// state adds a badge shape plus a header sentence so nothing is carried by
/// colour alone.
@MainActor
public final class MenuBarController {
    private let model: AppModel
    private let source: MenuPanelSource
    private let actions: (MenuAction) -> Void
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var modelChanges: AnyCancellable?

    public init(model: AppModel, source: MenuPanelSource, actions: @escaping (MenuAction) -> Void) {
        self.model = model
        self.source = source
        self.actions = actions
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    }

    public func install() {
        guard let button = statusItem.button else {
            preconditionFailure("the status item has no button to draw into")
        }

        button.target = self
        button.action = #selector(togglePanel)
        button.setAccessibilityLabel(model.menuGlyph.accessibilityLabel)

        let glyph = MenuBarGlyphHostingView(rootView: MenuBarGlyph(model: model))
        glyph.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])

        popover.behavior = .transient
        popover.animates = true

        modelChanges = model.objectWillChange.sink { [weak self] _ in
            // The published change lands after this fires, so the label is read
            // on the next turn of the run loop.
            DispatchQueue.main.async { self?.refreshAccessibility() }
        }
    }

    @objc
    private func togglePanel() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        popover.contentViewController = NSHostingController(
            rootView: MenuBarPanel(
                model: source.panel(),
                perform: { [weak self] action in
                    self?.popover.performClose(nil)
                    self?.actions(action)
                }
            )
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func refreshAccessibility() {
        statusItem.button?.setAccessibilityLabel(model.menuGlyph.accessibilityLabel)
    }
}

/// The status item's own view. It draws the glyph and nothing else: clicks
/// belong to the button underneath, so the hosting view stays out of hit
/// testing entirely.
private final class MenuBarGlyphHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// The glyph, driven by the model and by elapsed time while it pulses.
private struct MenuBarGlyph: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.menuGlyph.pulses && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: false)) { context in
                    MenuBarGlyphView(
                        state: model.menuGlyph,
                        elapsed: context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: MenuBarGlyphPulse.period)
                    )
                }
            } else {
                MenuBarGlyphView(state: model.menuGlyph)
            }
        }
        .frame(
            width: MenuBarGlyphMetrics.glyphSize + MenuBarGlyphMetrics.badgeDiameter,
            height: MenuBarGlyphMetrics.glyphSize + MenuBarGlyphMetrics.badgeDiameter
        )
    }
}
