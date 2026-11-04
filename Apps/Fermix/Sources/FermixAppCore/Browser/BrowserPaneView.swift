import AppKit
import SwiftUI

/// The browser pane's own measures (redlines §8 decision 37). The pane's
/// width is its column's (`BrowserColumn`): 600pt as the window widens for it,
/// then as wide as the person drags it.
enum BrowserPaneMetrics {
    /// Every tab is this wide, its title truncated, so a title that arrives
    /// as its page loads never moves the tabs after it, and the row scrolled
    /// to the tab in front stays there.
    static let tabWidth: Double = 160
    /// Between two tabs, and what the strip leaves at the toolbar's ends.
    static let tabGap: Double = Spacing.xs
    static let stripInset: Double = Spacing.m
    /// A tab's close control, a small circle inside the regular row.
    static let tabCloseSize: Double = 16
    static let tabCloseSymbolSize: Double = 9
    /// The lock in the address capsule, a glyph beside the address rather than
    /// a control.
    static let lockSymbolSize: Double = 10
}

/// The words the pane draws for a tab and a page's dialog.
enum BrowserText {
    /// A file tab is named by its file, whatever its page calls itself. Any
    /// other tab is named by its page's title, then by the page's host while
    /// the title has not arrived, then as a new tab.
    static func tabTitle(title: String, url: URL?, file: URL? = nil, fileName: String? = nil) -> String {
        if let file { return fileName ?? file.lastPathComponent }
        guard title.isEmpty else { return title }
        guard let host = url?.host, !host.isEmpty else { return ProductStrings[.browserUntitledTab] }

        return host
    }

    /// A file's address is its path, the home folder written `~`.
    static func address(of file: URL) -> String {
        (file.path as NSString).abbreviatingWithTildeInPath
    }

    /// The file tab's own way out, named by the app that opens its file.
    static func openIn(_ app: String) -> String {
        String(format: ProductStrings[.browserOpenInAppFormat], app)
    }

    /// A dialog speaks for the website that raised it.
    static func dialogTitle(origin: String) -> String {
        String(format: ProductStrings[.browserDialogTitleFormat], speaker(origin))
    }

    /// A page's dialog is titled by the website that raised it, the pane's
    /// question before a link opens another app by that app, and its question
    /// before a file outside the Fermix home loads by that file.
    static func dialogTitle(_ dialog: BrowserDialog) -> String {
        switch dialog.kind {
        case .openApp(let app): return String(format: ProductStrings[.browserOpenAppTitleFormat], app)
        case .openFile(let name): return String(format: ProductStrings[.browserOpenFileTitleFormat], name)
        case .alert, .confirm, .prompt: return dialogTitle(origin: dialog.origin)
        }
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

/// The browser pane (plan §4.3): the primary window's trailing column
/// (`BrowserColumn`), beside the body and inside the frame.
///
/// Its tabs stand in its own part of the window's toolbar, over the pane,
/// each a pill the toolbar's height. Under the toolbar, a header row on the
/// frame's own glass carries the address capsule between back, forward and
/// reload, and the pane's own two actions, with a progress hairline along its
/// foot; under it the page in front, hosted as the engine built it. The
/// pane removes no title from the toolbar and draws no page title of its own.
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
    /// The pane's width, which its tab strip fits in the toolbar over it.
    @State private var paneWidth: Double = 0

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
        // Any width at all: the column's width is the column's, and a page or
        // an address that would like more never widens it.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .leading) { BrowserPaneEdge() }
        .background(alignment: .topLeading) { BrowserShortcuts(browser: browser) }
        .onGeometryChange(for: Double.self) { proxy in
            proxy.size.width
        } action: { width in
            paneWidth = width
        }
        .toolbar { tabsItem }
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
    /// questions before another app opens or a file loads are Open and Cancel.
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
        case .openApp, .openFile:
            Button(ProductStrings[.browserOpenAppOpen]) { browser.answer(.confirmed) }
            Button(ProductStrings[.browserDialogCancel], role: .cancel) { browser.answer(.dismissed) }
        }
    }

    /// The tabs, in the toolbar over the pane, as wide as the pane less the
    /// toolbar's ends. They draw their own pills, so the toolbar's shared
    /// glass, which would wrap the whole strip in one more capsule, is off.
    @ToolbarContentBuilder
    private var tabsItem: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) { tabStrip }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { tabStrip }
        }
    }

    private var tabStrip: some View {
        BrowserTabStrip(browser: browser, tabs: model.tabs, selected: model.selectedTabID, host: model.host)
            .frame(width: max(0, paneWidth - 2 * BrowserPaneMetrics.stripInset), alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
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
                .accessibilityLabel(BrowserText.tabTitle(title: tab.title, url: tab.url, file: tab.file, fileName: tab.fileName))
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

/// The pane's keyboard, beyond what its visible controls carry: a private
/// tab, the caret in the address field, and the zoom of the page in front, a
/// step either way, back to its actual size, or a picture fitted to the pane,
/// with the keys Safari and Preview use. Command-T is the new-tab capsule's
/// and Command-W the close control of the tab in front.
private struct BrowserShortcuts: View {
    let browser: BrowserCoordinator

    var body: some View {
        ZStack {
            Button(ProductStrings[.browserNewPrivateTab]) { browser.newTab(profile: .private) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button(ProductStrings[.browserAddress]) { browser.focusAddress() }
                .keyboardShortcut("l", modifiers: .command)
            Button(ProductStrings[.browserZoomIn]) { browser.zoom(.larger) }
                .keyboardShortcut("=", modifiers: .command)
            Button(ProductStrings[.browserZoomOut]) { browser.zoom(.smaller) }
                .keyboardShortcut("-", modifiers: .command)
            Button(ProductStrings[.browserActualSize]) { browser.zoom(.actualSize) }
                .keyboardShortcut("0", modifiers: .command)
            Button(ProductStrings[.browserZoomToFit]) { browser.zoom(.fit) }
                .keyboardShortcut("9", modifiers: .command)
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The tabs, in a row that scrolls sideways once they no longer fit, as a
/// task with many tabs fills it, then the round pill that opens a new one,
/// which stays at the row's end. The tab in front is scrolled into view
/// whenever it changes, a new one included, and an end with more tabs past it
/// fades, as the chat's sideways rows do.
private struct BrowserTabStrip: View {
    let browser: BrowserCoordinator
    let tabs: [BrowserTab]
    let selected: BrowserTab.ID?
    /// Whose each tab is, and which tasks are being cancelled.
    let host: BrowserHostReducer

    /// Which ends have more tabs past them, which fade.
    @State private var edges = ChatStripEdges(leading: false, trailing: false)
    /// The tab the row is scrolled to: the one in front, centred, so it is
    /// never left under a fading end.
    @State private var position: BrowserTab.ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: BrowserPaneMetrics.tabGap) {
            tabRow
                .frame(maxWidth: tabsWidth > 0 ? tabsWidth : nil)
            newTab
            Spacer(minLength: 0)
        }
    }

    /// The tabs' own width, so a row with room to spare is only as wide as
    /// its tabs and the new-tab pill follows the last of them.
    private var tabsWidth: Double {
        let count = Double(tabs.count)
        return count * BrowserPaneMetrics.tabWidth + max(0, count - 1) * BrowserPaneMetrics.tabGap
    }

    private var tabRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: BrowserPaneMetrics.tabGap) {
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
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        // A position the row resolves as it lays out, so a tab opened in
        // front is scrolled to once it is in the row, not before.
        .scrollPosition(id: $position, anchor: .center)
        .onScrollGeometryChange(for: ChatStripEdges.self, of: { ChatStripEdges(ChatStripScroll($0)) }) { _, now in
            edges = now
        }
        .mask { ChatStripFade(edges: edges) }
        .onChange(of: selected, initial: true) { _, now in
            withAnimation(reduceMotion ? nil : .default) { position = now }
        }
    }

    private var newTab: some View {
        Button { browser.newTab(profile: .shared) } label: {
            Label(ProductStrings[.browserNewTab], systemImage: "plus")
                .labelStyle(.iconOnly)
                .frame(width: ToolbarPillMetrics.height, height: ToolbarPillMetrics.height)
                .contentShape(Circle())
                .toolbarPill(in: Circle(), strong: true)
        }
            .buttonStyle(.plain)
            .keyboardShortcut("t", modifiers: .command)
            .help(ProductStrings[.browserNewTab])
            .accessibilityLabel(ProductStrings[.browserNewTab])
            .contextMenu {
                Button(ProductStrings[.browserNewPrivateTab]) { browser.newTab(profile: .private) }
            }
    }
}

/// One tab: its title, a mark where it is private, a file or a task's, and
/// its close control.
///
/// Every tab is a pill the toolbar's height, as a surface's search field is
/// (`toolbarPill`): the one in front in full, the others on a quieter pill.
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
                    if tab.profile == .file {
                        Image(systemName: "doc")
                            .accessibilityLabel(ProductStrings[.browserFileTab])
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
        .padding(.trailing, Spacing.xs)
        .frame(width: BrowserPaneMetrics.tabWidth, height: ToolbarPillMetrics.height)
        .toolbarPill(in: Capsule(), strong: isSelected)
        .onHover { isHovering = $0 }
        .help(title)
    }

    private var title: String {
        BrowserText.tabTitle(title: tab.title, url: tab.url, file: tab.file, fileName: tab.fileName)
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
/// pane's own actions: the page in the person's own browser, or a file tab's
/// file in the app that opens it and in Finder, after a picture's fit, then
/// hiding the pane.
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

            if tab.profile == .file {
                fileActions
            } else {
                control(.browserOpenInBrowser, symbol: "arrow.up.forward.app", enabled: tab.url != nil) {
                    browser.openInSystemBrowser()
                }
            }
            control(.browserHide, symbol: "sidebar.trailing", enabled: true) { browser.closePane() }
        }
        .onAppear {
            draft = shownAddress
            // A blank tab is opened to be typed into; a file tab is opened
            // to be read, before or after its file loads.
            if tab.url == nil, tab.profile != .file { addressFocused = true }
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

    /// A file tab's way out: its file in the app the tab offers it to, where
    /// it offers one, which it never does for text, markup or a script, and
    /// its file selected in Finder. A picture tab first offers the one zoom it
    /// has a control for: its actual size while it is fitted to the pane, and
    /// the fit again once it is magnified.
    @ViewBuilder
    private var fileActions: some View {
        if tab.fileKind == .image {
            let fitted = !tab.isMagnified
            control(
                fitted ? .browserActualSize : .browserZoomToFit,
                symbol: fitted ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                enabled: tab.url != nil
            ) {
                tab.zoom(fitted ? .actualSize : .fit)
            }
        }
        if let fileApp = tab.fileApp {
            control(named: BrowserText.openIn(fileApp.name), symbol: "arrow.up.forward.app", enabled: true) {
                browser.openFileInApp()
            }
        }
        control(.browserShowInFinder, symbol: "folder", enabled: true) { browser.showInFinder() }
    }

    /// The address capsule: the page's address, with the lock while every
    /// resource on it came over a secure connection, in a field that loads
    /// what is typed on Return. A file tab's is its path, to read and copy
    /// and never to type into, since the tab loads nothing else.
    private var address: some View {
        HStack(spacing: Spacing.xxs) {
            if let file = tab.file {
                Text(BrowserText.address(of: file))
                    .fermixType(Typography.style(.callout))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(ProductStrings[.browserAddress])
                    .accessibilityValue(BrowserText.address(of: file))
            } else {
                webAddress
            }
        }
        .padding(.horizontal, Spacing.s)
        .frame(maxWidth: .infinity, minHeight: HitTarget.rowAction)
        .background(ButtonRecipe.shape.fill(ButtonRecipe.secondaryFill.color))
        .overlay(ButtonRecipe.shape.strokeBorder(ButtonRecipe.secondaryBorder.color, lineWidth: Stroke.hairline))
    }

    @ViewBuilder
    private var webAddress: some View {
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

    /// One of the row's symbol capsules, named for VoiceOver and the pointer.
    private func control(
        _ name: ProductStringKey,
        symbol: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        control(named: ProductStrings[name], symbol: symbol, enabled: enabled, action: action)
    }

    private func control(
        named name: String,
        symbol: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(name, systemImage: symbol)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(SecondaryButtonStyle(.row))
        .disabled(!enabled)
        .help(name)
        .accessibilityLabel(name)
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


/// A hairline down the pane's leading edge, through the toolbar's band, which
/// sets the pane apart from the body beside it and marks the edge a person
/// drags to share the window between them (owner, 2026-11-03, after the line
/// ChatGPT draws beside its side pane). Paint only: the drag is the column's
/// own divider under it.
private struct BrowserPaneEdge: View {
    var body: some View {
        Rectangle()
            .fill(Palette.hairline(.standard).color)
            .frame(width: Stroke.hairline)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
