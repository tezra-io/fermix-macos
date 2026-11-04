import AppKit
import SwiftUI

/// The composer: a capsule field that grows to a few lines, and one capsule
/// action at its trailing edge.
///
/// Return sends and Shift-Return starts a new line, and Enter, the keypad's
/// key or fn-Return on a laptop, does what Return does. The action is Send, the
/// surface's primary action and so its default button, until a turn is
/// running; then it is Cancel, which is never the default, so a Return typed
/// while a reply is coming cannot cancel it. A message with neither words nor
/// a file is never sent: the action is unavailable and Return does nothing.
///
/// Where the engine takes files, an attach button stands at the leading edge,
/// and a file dropped on the chat or pasted joins the message too: each shows
/// as a chip over the field until it is sent or taken out, and the message
/// waits until the engine holds every one (`ChatAttachments`).
///
/// A draft that is a slash and the start of a word asks for a command: the
/// engine's commands that match stand over the composer (`ChatCommandPalette`),
/// Up and Down choose one, Return or Tab writes it into the draft, and
/// Escape puts the list away until the draft changes.
///
/// Not connected, the whole composer is unavailable and the connection's own
/// sentence stands over it. A request made then would wait in the outbox, but
/// the owner could not see it go. The one exception is a desktop whose server
/// is away or whose home is moving (M75): the daemon's sentence says the
/// message is kept, so the composer takes it into the outbox, where it shows
/// as sending until the next connection carries it.
struct ChatComposer: View {
    @Binding var draft: String
    let connection: CompanionConnection
    let turn: CompanionTurn?
    @ObservedObject var attachments: ChatAttachments
    /// The engine's slash commands, which the palette offers.
    let commands: [CompanionCommand]
    /// Whether a file is being dragged over the chat.
    let dropping: Bool
    let send: () -> Void
    let cancel: (String) -> Void

    @FocusState private var focused: Bool
    /// The command the palette has chosen, by its place in the list.
    @State private var choice = 0
    /// The draft Escape put the palette away at: it stays away while the
    /// draft is this.
    @State private var paletteDismissed: String?
    /// The key monitor that takes a paste of files or a picture, installed
    /// while the field has focus.
    @State private var pasteMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let sentence = connection.sentence {
                Text(sentence)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                if !attachments.items.isEmpty {
                    ChatAttachmentChips(attachments: attachments)
                }

                HStack(alignment: .lastTextBaseline, spacing: Spacing.xs) {
                    if attachments.inbox != nil {
                        attachButton
                    }
                    field
                    action
                }
            }
            .padding(attachments.inbox == nil ? ChatMetrics.composerInset : ChatMetrics.composerAttachInset)
            .background(shape.fill(Palette.chipFill.color))
            .overlay(shape.strokeBorder(border, lineWidth: dropping ? Stroke.heroBorder : Stroke.hairline))
            // The palette hangs from a line along the composer's top edge, so
            // it stands over the composer, as tall as it needs, and moves
            // nothing.
            .overlay(alignment: .top) {
                Color.clear
                    .frame(height: 0)
                    .overlay(alignment: .bottom) {
                        if let matches = paletteMatches {
                            ChatCommandPalette(commands: matches, choice: choice, pick: pick)
                                .padding(.bottom, Spacing.xs)
                        }
                    }
            }
            .disabled(!connection.acceptsMessages)
        }
        .onAppear { focused = true }
        .onChange(of: connection) { _, now in
            guard now.acceptsMessages else { return }

            focused = true
        }
        .onChange(of: draft) { choice = 0 }
        .onChange(of: focused) { _, now in
            now ? watchPaste() : stopWatchingPaste()
        }
        .onDisappear { stopWatchingPaste() }
    }

    private var field: some View {
        TextField(ProductStrings[.chatComposerPrompt], text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(ChatMetrics.composerLines)
            .fermixType(Typography.style(.body))
            .focused($focused)
            .onKeyPress(keys: Self.sendKeys, phases: .down, action: returnPressed)
            .onKeyPress(keys: [.upArrow, .downArrow, .tab, .escape], phases: .down, action: paletteKey)
    }

    /// Return, and Enter: a key of its own, which the default button's Return
    /// never matches, so left to the field it would end editing and select
    /// the draft rather than send it.
    static let sendKeys: Set<KeyEquivalent> = [.return, KeyEquivalent("\u{3}")]

    private var attachButton: some View {
        Button(action: chooseFiles) {
            Image(systemName: "paperclip")
                .font(.system(size: ChatMetrics.attachGlyph))
                .frame(width: HitTarget.rowAction, height: HitTarget.rowAction)
                .contentShape(Rectangle())
        }
        .buttonStyle(ChatActionButtonStyle())
        .help(ProductStrings[.chatAttach])
        .accessibilityLabel(ProductStrings[.chatAttach])
    }

    /// Send and Cancel stand in one place and one is shown. Both stay in the
    /// layout, so the one that appears while the composer is still moving to
    /// the bottom edge moves with it instead of landing there first. The one
    /// not shown is unavailable, so Return never reaches a hidden Send.
    private var action: some View {
        ZStack {
            PrimaryAction(ProductStrings[.chatSend], size: .row, action: send)
                .disabled(!canSend)
                .shown(turn == nil)

            Button(ProductStrings[.chatCancel]) {
                guard let request = turn?.inReplyTo else { return }

                cancel(request)
            }
            .buttonStyle(SecondaryButtonStyle(.row))
            // A turn joined midway names no request, and a cancel names one.
            .disabled(turn?.inReplyTo == nil)
            .shown(turn != nil)
        }
    }

    /// Shift-Return is a line break where the caret is, which is what the
    /// field editor inserts for Option-Return; left to itself it would end
    /// editing. Return alone sends, or, while the palette stands, writes its
    /// chosen command. The send button's own Return reaches it first while it
    /// can send, so this answers the Return it leaves, a draft that cannot be
    /// sent or a turn running, and every Enter.
    private func returnPressed(_ press: KeyPress) -> KeyPress.Result {
        if let matches = paletteMatches {
            pick(matches[min(choice, matches.count - 1)])
            return .handled
        }
        guard press.modifiers.contains(.shift) else {
            if canSend { send() }
            return .handled
        }

        NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
        return .handled
    }

    /// Up, Down, Tab and Escape steer the palette while it stands, and are
    /// the field's own otherwise.
    private func paletteKey(_ press: KeyPress) -> KeyPress.Result {
        guard let matches = paletteMatches else { return .ignored }

        switch press.key {
        case .upArrow: choice = max(0, choice - 1)
        case .downArrow: choice = min(matches.count - 1, choice + 1)
        case .tab: pick(matches[min(choice, matches.count - 1)])
        default: paletteDismissed = draft
        }
        return .handled
    }

    /// The commands the draft asks for, nil while the palette does not stand.
    private var paletteMatches: [CompanionCommand]? {
        guard focused, paletteDismissed != draft,
              let matches = ChatCommandFilter.matches(commands, draft: draft), !matches.isEmpty
        else { return nil }

        return matches
    }

    /// Writes the command into the draft, ready for what it takes.
    private func pick(_ command: CompanionCommand) {
        draft = ChatCommandFilter.draft(for: command)
        focused = true
    }

    private var canSend: Bool {
        turn == nil && attachments.sendable && (!isBlank || !attachments.items.isEmpty)
    }

    private var isBlank: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var border: Color {
        dropping ? Palette.accent.color : Palette.hairline(.standard).color
    }

    /// A capsule while the field is one line, the in-window control height,
    /// and the same corners once it grows.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HitTarget.button / 2, style: .continuous)
    }

    // MARK: - Files

    private func chooseFiles() {
        guard let window = NSApp.keyWindow else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = ProductStrings[.chatAttach]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }

            attachments.add(panel.urls)
            focused = true
        }
    }

    /// Command-V reaches the menu's Paste before the field sees it, so a
    /// paste of files or a picture is taken here, ahead of the menu, while
    /// the field has focus; a paste of words is left to the field.
    private func watchPaste() {
        guard pasteMonitor == nil else { return }

        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [attachments] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  attachments.inbox != nil
            else { return event }

            return MainActor.assumeIsolated { ChatPaste.take(from: .general, into: attachments) } ? nil : event
        }
    }

    private func stopWatchingPaste() {
        guard let pasteMonitor else { return }

        NSEvent.removeMonitor(pasteMonitor)
        self.pasteMonitor = nil
    }
}

/// What a paste into the composer attaches: the files the pasteboard names,
/// as Finder copies them, or else a picture with no words beside it, as a
/// screenshot copies one.
@MainActor
enum ChatPaste {
    /// Attaches what the pasteboard holds, and says whether it held a file
    /// or a picture to attach.
    static func take(from board: NSPasteboard, into attachments: ChatAttachments) -> Bool {
        let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            attachments.add(files)
            return true
        }
        guard board.string(forType: .string) == nil, let png = picture(on: board) else { return false }

        attachments.addPicture(png: png)
        return true
    }

    private static func picture(on board: NSPasteboard) -> Data? {
        if let png = board.data(forType: .png) { return png }
        guard let tiff = board.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff) else { return nil }

        return bitmap.representation(using: .png, properties: [:])
    }
}

private extension View {
    /// Drawn and reachable, or neither while keeping its place in the layout.
    func shown(_ shown: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}
