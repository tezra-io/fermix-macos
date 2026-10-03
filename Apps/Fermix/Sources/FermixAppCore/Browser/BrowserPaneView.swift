import AppKit
import SwiftUI

/// The browser pane's own measures (redlines §8 decision 37). The pane's
/// width is the split's (`PaneSplit`): 600pt as the window widens for it, more
/// where the body cannot use the width, down to its floor on a small screen.
enum BrowserPaneMetrics {
    /// A tab gives up width to its neighbours down to this, and never takes
    /// more than the widest; its title truncates in between.
    static let tabMinWidth: Double = 72
    static let tabMaxWidth: Double = 180
    /// A tab's close control, a small circle inside the regular row.
    static let tabCloseSize: Double = 16
    static let tabCloseSymbolSize: Double = 9
    /// The lock in the address capsule, a glyph beside the address rather than
    /// a control.
    static let lockSymbolSize: Double = 10
}

/// The words the pane draws for a tab and a page's dialog.
enum BrowserText {
    /// A tab is named by its page's title, then by the page's host while the
    /// title has not arrived, then as a new tab.
    static func tabTitle(title: String, url: URL?) -> String {
        guard title.isEmpty else { return title }
        guard let host = url?.host, !host.isEmpty else { return ProductStrings[.browserUntitledTab] }

        return host
    }

    /// A dialog speaks for the website that raised it.
    static func dialogTitle(origin: String) -> String {
        String(format: ProductStrings[.browserDialogTitleFormat], speaker(origin))
    }

    /// A page's dialog is titled by the website that raised it, and the pane's
    /// question before a link opens another app by that app.
    static func dialogTitle(_ dialog: BrowserDialog) -> String {
        guard case .openApp(let app) = dialog.kind else { return dialogTitle(origin: dialog.origin) }

        return String(format: ProductStrings[.browserOpenAppTitleFormat], app)
    }

    /// The pane's question before a link opens another app says which website
    /// asks.
    static func openAppMessage(origin: String) -> String {
        String(format: ProductStrings[.browserOpenAppMessageFormat], speaker(origin))
    }

    private static func speaker(_ origin: String) -> String {
        origin.isEmpty ? ProductStrings[.browserDialogThisPage] : origin
    }
}

/// The browser pane (plan §4.3): the third pane of the primary window, beside
/// the body and inside the frame.
///
/// A header row on the frame's own glass, under the band, carries the tab
/// strip, the address capsule between back, forward and reload, and the pane's
/// own two actions, with a progress hairline along its foot; under it the page
/// in front, hosted as the engine built it. The window's toolbar belongs to the
/// surface beside the pane, so the pane draws nothing in it, removes no title
/// from it, and draws no page title of its own.
///
/// It draws nothing while the pane is closed, and it observes the browser's
/// model rather than the window doing so, so a page loading redraws the pane
/// and never the rail or the body.
struct BrowserPaneView: View {
    let browser: BrowserCoordinator
    @ObservedObject private var model: BrowserModel
    /// What the person types into a page's prompt, reset to the page's own
    /// default as each prompt arrives.
    @State private var promptText = ""

    init(browser: BrowserCoordinator) {
        self.browser = browser
        self.model = browser.model
    }

    var body: some View {
        if model.isOpen {
            pane
        }
    }

    private var pane: some View {
        VStack(spacing: 0) {
            header
            if let notice = model.notice {
                BrowserNotice(text: notice)
            }
            page
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .topLeading) { BrowserShortcuts(browser: browser) }
        .alert(
            model.dialog.map { BrowserText.dialogTitle($0.dialog) } ?? "",
            isPresented: dialogShown,
            presenting: model.dialog
        ) { request in
            dialogActions(request.dialog)
        } message: { request in
            Text(request.dialog.message)
        }
        .onChange(of: model.dialog?.id) {
            guard case .prompt(let defaultText)? = model.dialog?.dialog.kind else { return }

            promptText = defaultText
        }
    }

    /// A page's dialog, answered once: OK alone for an alert, OK and Cancel for
    /// a confirmation, and a field above them for a prompt, named by the page's
    /// own question, which the alert already shows as its message. The pane's
    /// question before another app opens is Open and Cancel.
    @ViewBuilder
    private func dialogActions(_ dialog: BrowserDialog) -> some View {
        switch dialog.kind {
        case .alert:
            Button(ProductStrings[.browserDialogOK]) { browser.answer(.confirmed) }
        case .confirm:
            Button(ProductStrings[.browserDialogOK]) { browser.answer(.confirmed) }
            Button(ProductStrings[.browserDialogCancel], role: .cancel) { browser.answer(.dismissed) }
        case .prompt:
            TextField(dialog.message, text: $promptText)
                .labelsHidden()
            Button(ProductStrings[.browserDialogOK]) { browser.answer(.text(promptText)) }
            Button(ProductStrings[.browserDialogCancel], role: .cancel) { browser.answer(.dismissed) }
        case .openApp:
            Button(ProductStrings[.browserOpenAppOpen]) { browser.answer(.confirmed) }
            Button(ProductStrings[.browserDialogCancel], role: .cancel) { browser.answer(.dismissed) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            BrowserTabStrip(browser: browser, tabs: model.tabs, selected: model.selectedTabID, host: model.host)
            if let tab = model.selectedTab {
                BrowserNavigationRow(browser: browser, tab: tab, focusRequests: model.addressFocusRequests)
                    .id(tab.id)
            }
        }
        .padding(Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { FrameGlass() }
        .overlay(alignment: .bottom) {
            if let tab = model.selectedTab {
                BrowserProgressLine(tab: tab)
            }
        }
    }

    /// The page in front, or, in a pane opened with no tab, the one sentence
    /// that says what the pane is for.
    @ViewBuilder
    private var page: some View {
        if let tab = model.selectedTab {
            BrowserPageHost(browser: browser)
                .accessibilityLabel(BrowserText.tabTitle(title: tab.title, url: tab.url))
        } else {
            EmptyState(model: EmptyStateModel(message: ProductStrings[.browserEmpty]))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Presented while a request waits. SwiftUI clears the binding as the alert
    /// goes, and every way out of it answers the page through an action first.
    private var dialogShown: Binding<Bool> {
        Binding(
            get: { model.dialog != nil },
            set: { shown in
                guard !shown, model.dialog != nil else { return }

                browser.answer(.dismissed)
            }
        )
    }
}

/// The pane's keyboard, beyond what its visible controls carry: a private tab
/// and the caret in the address field. Command-T is the new-tab capsule's and
/// Command-W the close control of the tab in front.
private struct BrowserShortcuts: View {
    let browser: BrowserCoordinator

    var body: some View {
        ZStack {
            Button(ProductStrings[.browserNewPrivateTab]) { browser.newTab(profile: .private) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button(ProductStrings[.browserAddress]) { browser.focusAddress() }
                .keyboardShortcut("l", modifiers: .command)
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The tabs, then the plain capsule that opens a new one.
private struct BrowserTabStrip: View {
    let browser: BrowserCoordinator
    let tabs: [BrowserTab]
    let selected: BrowserTab.ID?
    /// Whose each tab is, and which tasks are being cancelled.
    let host: BrowserHostReducer

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            ForEach(tabs) { tab in
                let task = host.owner(of: tab.id)?.task
                BrowserTabChip(
                    browser: browser,
                    tab: tab,
                    isSelected: tab.id == selected,
                    task: task,
                    cancelling: task.map(host.pendingRelease.contains) == true
                )
            }

            Button { browser.newTab(profile: .shared) } label: {
                Label(ProductStrings[.browserNewTab], systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(SecondaryButtonStyle(.row))
            .keyboardShortcut("t", modifiers: .command)
            .help(ProductStrings[.browserNewTab])
            .accessibilityLabel(ProductStrings[.browserNewTab])
            .contextMenu {
                Button(ProductStrings[.browserNewPrivateTab]) { browser.newTab(profile: .private) }
            }

            Spacer(minLength: 0)
        }
    }
}

/// One tab: its title, a mark where it is private or a task's, and its close
/// control.
///
/// The tab in front sits on the secondary capsule; the others are plain words.
/// Its close control carries Command-W, so the key closes the tab in front and
/// the last one takes the pane with it. A task's tab is not the person's to
/// close: the same control cancels the task, once, and the task's release
/// takes the tab.
private struct BrowserTabChip: View {
    let browser: BrowserCoordinator
    @ObservedObject var tab: BrowserTab
    let isSelected: Bool
    /// The task the tab belongs to, where it is a task's.
    let task: BrowserTaskID?
    /// Whether the person asked to cancel that task and its release has not
    /// come yet.
    let cancelling: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            Button { browser.select(tab) } label: {
                HStack(spacing: Spacing.xxs) {
                    if task != nil {
                        Image(systemName: "sparkles")
                            .accessibilityLabel(ProductStrings[.browserTaskTab])
                    }
                    if tab.profile == .private {
                        Image(systemName: "eye.slash")
                            .accessibilityLabel(ProductStrings[.browserPrivateTab])
                    }
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            close
        }
        .fermixType(Typography.style(.callout))
        .foregroundStyle((isSelected ? Palette.ink : Palette.secondary).color)
        .padding(.leading, Spacing.s)
        .padding(.trailing, Spacing.xxs)
        .frame(
            minWidth: BrowserPaneMetrics.tabMinWidth,
            maxWidth: BrowserPaneMetrics.tabMaxWidth,
            minHeight: HitTarget.rowAction
        )
        .background {
            if isSelected {
                ButtonRecipe.shape.fill(ButtonRecipe.secondaryFill.color)
                    .overlay(ButtonRecipe.shape.strokeBorder(ButtonRecipe.secondaryBorder.color, lineWidth: Stroke.hairline))
            }
        }
        .onHover { isHovering = $0 }
        .help(title)
    }

    private var title: String {
        BrowserText.tabTitle(title: tab.title, url: tab.url)
    }

    /// Shown on the tab in front and on the one under the pointer, and always
    /// there for VoiceOver. On a task's tab it cancels the task, and it is
    /// dimmed while that cancel is on its way.
    private var close: some View {
        Button { browser.close(tab) } label: {
            Label(ProductStrings[closeName], systemImage: task == nil ? "xmark" : "stop.fill")
                .labelStyle(.iconOnly)
                .font(.system(size: BrowserPaneMetrics.tabCloseSymbolSize, weight: .semibold))
                .frame(width: BrowserPaneMetrics.tabCloseSize, height: BrowserPaneMetrics.tabCloseSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(cancelling)
        .opacity(isSelected || isHovering ? 1 : 0)
        .keyboardShortcut(isSelected ? KeyboardShortcut("w", modifiers: .command) : nil)
        .help(ProductStrings[closeName])
        .accessibilityLabel(ProductStrings[closeName])
    }

    private var closeName: ProductStringKey {
        guard task != nil else { return .browserCloseTab }

        return cancelling ? .browserCancellingTask : .browserCancelTask
    }
}

/// Back, forward, reload or cancel loading, the address capsule, and the
/// pane's own two actions.
private struct BrowserNavigationRow: View {
    let browser: BrowserCoordinator
    @ObservedObject var tab: BrowserTab
    let focusRequests: Int

    @State private var draft = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            control(.browserBack, symbol: "chevron.backward", enabled: tab.canGoBack) { tab.back() }
            control(.browserForward, symbol: "chevron.forward", enabled: tab.canGoForward) { tab.forward() }
            if tab.isLoading {
                control(.browserCancelLoading, symbol: "xmark", enabled: true) { tab.stop() }
            } else {
                control(.browserReload, symbol: "arrow.clockwise", enabled: tab.url != nil) { tab.reload() }
            }

            address

            control(.browserOpenInBrowser, symbol: "arrow.up.forward.app", enabled: tab.url != nil) {
                browser.openInSystemBrowser()
            }
            control(.browserHide, symbol: "sidebar.trailing", enabled: true) { browser.closePane() }
        }
        .onAppear {
            draft = shownAddress
            // A blank tab is opened to be typed into.
            if tab.url == nil { addressFocused = true }
        }
        .onChange(of: focusRequests) { addressFocused = true }
        .onChange(of: tab.url) {
            guard !addressFocused else { return }

            draft = shownAddress
        }
    }

    private var shownAddress: String {
        tab.url?.absoluteString ?? ""
    }

    /// The address capsule: the page's address, with the lock while every
    /// resource on it came over a secure connection, and a field that loads
    /// what is typed on Return.
    private var address: some View {
        HStack(spacing: Spacing.xxs) {
            if tab.hasOnlySecureContent {
                Image(systemName: "lock.fill")
                    .font(.system(size: BrowserPaneMetrics.lockSymbolSize, weight: .semibold))
                    .foregroundStyle(Palette.secondary.color)
                    .accessibilityLabel(ProductStrings[.browserSecure])
            }

            TextField(ProductStrings[.browserAddressPrompt], text: $draft)
                .textFieldStyle(.plain)
                .fermixType(Typography.style(.callout))
                .focused($addressFocused)
                .accessibilityLabel(ProductStrings[.browserAddress])
                .onSubmit {
                    browser.load(address: draft)
                    addressFocused = false
                }
                .onExitCommand {
                    draft = shownAddress
                    addressFocused = false
                }
        }
        .padding(.horizontal, Spacing.s)
        .frame(maxWidth: .infinity, minHeight: HitTarget.rowAction)
        .background(ButtonRecipe.shape.fill(ButtonRecipe.secondaryFill.color))
        .overlay(ButtonRecipe.shape.strokeBorder(ButtonRecipe.secondaryBorder.color, lineWidth: Stroke.hairline))
    }

    /// One of the row's symbol capsules, named for VoiceOver and the pointer.
    private func control(
        _ name: ProductStringKey,
        symbol: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(ProductStrings[name], systemImage: symbol)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(SecondaryButtonStyle(.row))
        .disabled(!enabled)
        .help(ProductStrings[name])
        .accessibilityLabel(ProductStrings[name])
    }
}

/// How far the page in front has loaded, as a hairline along the header's
/// foot, drawn only while it loads.
private struct BrowserProgressLine: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        GeometryReader { proxy in
            Palette.accent.color
                .frame(width: proxy.size.width * tab.estimatedProgress, height: Stroke.hairline)
        }
        .frame(height: Stroke.hairline)
        .opacity(tab.isLoading ? 1 : 0)
        .accessibilityHidden(true)
    }
}

/// The pane's one sentence, on the frame under the header.
private struct BrowserNotice: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle")
                .accessibilityHidden(true)
        }
        .fermixType(Typography.style(.calloutSmall))
        .foregroundStyle(Palette.secondary.color)
        .padding(.horizontal, Spacing.s)
        .padding(.bottom, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { FrameGlass() }
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The pane's page area, hosted as the engine built each page.
///
/// It only builds the area and tells the coordinator it is there and when it
/// is gone: the coordinator owns where every page is (plan §4.10), so it moves
/// the page in front in and out, and a task's page to the host window when
/// the pane is hidden or the window covered, by reparenting. SwiftUI rebuilds
/// nothing around a page as it moves, and a page keeps its own scroll position
/// and state while it is out.
private struct BrowserPageHost: NSViewRepresentable {
    let browser: BrowserCoordinator

    func makeCoordinator() -> BrowserCoordinator {
        browser
    }

    func makeNSView(context: Context) -> BrowserPaneStage {
        let stage = BrowserPaneStage()
        browser.paneStageAppeared(stage)

        return stage
    }

    func updateNSView(_ stage: BrowserPaneStage, context: Context) {}

    static func dismantleNSView(_ stage: BrowserPaneStage, coordinator: BrowserCoordinator) {
        coordinator.paneStageGone(stage)
    }
}

/// The page area itself: the page it holds fills it.
final class BrowserPaneStage: NSView, BrowserPageStage {
    func hold(_ page: NSView) {
        guard page.superview !== self else { return }

        page.translatesAutoresizingMaskIntoConstraints = false
        addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: topAnchor),
            page.bottomAnchor.constraint(equalTo: bottomAnchor),
            page.leadingAnchor.constraint(equalTo: leadingAnchor),
            page.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    func release(_ page: NSView) {
        guard page.superview === self else { return }

        page.removeFromSuperview()
    }
}
