import SwiftUI

/// A voice note from the phone (M66 §3.4): a chip on its row's side in the
/// chip's fill, as the phone draws one, with its player on one line, drawn
/// as a sound's is (play, its waveform, the time) and named "Voice note" to
/// VoiceOver, and the transcript, the row's text, under it. A note with no
/// transcript, one still being transcribed or one that could not be, is the
/// player alone.
///
/// Its waveform's levels are read while the chip is on screen, through the
/// chat's previews, from the file the engine grants for the note only while
/// they are read, as a phone-side tile's preview is. It plays on the app's
/// one player from the file the engine grants when play is pressed, and the
/// player keeps that grant for as long as it holds the note
/// (`AppPlayer.play(ref:from:)`). A note whose bytes the engine no longer
/// has, found by either, shows Not available where the player would be,
/// with its transcript still under it.
struct ChatVoiceNote: View {
    let note: CompanionMediaRef
    let transcript: AttributedString
    /// Who sent it, which side it is drawn on and how VoiceOver names its
    /// transcript.
    let speaker: String?
    @ObservedObject var player: AppPlayer

    /// Whether the engine said, when play was last pressed or the levels
    /// were read, that it no longer has the note's bytes.
    @State private var gone = false
    /// The note's levels, once read.
    @State private var levels: SoundLevels?
    @State private var onScreen = false
    @Environment(\.chatRows) private var rows

    var body: some View {
        let user = ChatSpeaker.isUser(speaker)

        VStack(alignment: .leading, spacing: Spacing.xs) {
            if gone {
                notAvailable
            } else {
                playerRow
            }

            if !transcript.characters.isEmpty {
                Text(transcript)
                    .fermixType(Typography.style(.body))
                    .foregroundStyle(Palette.ink.color)
                    .textSelection(.enabled)
                    .accessibilityLabel(ChatSpeaker.name(role: speaker))
                    .accessibilityValue(String(transcript.characters))
            }
        }
        .padding(ChatMetrics.userChipPadding)
        .background(
            RoundedRectangle(cornerRadius: ChatMetrics.rowRadius, style: .continuous)
                .fill(Palette.chipFill.color)
        )
        .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
        .padding(user ? .leading : .trailing, ChatMetrics.userRowLeadingRoom)
        .accessibilityElement(children: .contain)
        .onScrollVisibilityChange(threshold: 0.01) { onScreen = $0 }
        .task(id: onScreen) {
            guard onScreen else { return }

            await readLevels()
        }
    }

    /// The note's levels. A note whose levels cannot be read keeps its
    /// resting bars, and still plays.
    private func readLevels() async {
        guard let rows, levels == nil, !gone else { return }

        let outcome = await rows.media.previews.levels(ChatLevelsRequest(note))
        guard !Task.isCancelled else { return }

        if case .made(.levels(let read)) = outcome { levels = read }
        if outcome == .missing { gone = true }
    }

    /// The player, its place observed only while the one player holds this
    /// note, so a tick redraws this chip and no other. Its length is the
    /// one its levels decoded once they are read, and the player's, read once
    /// the note is first played, until then (`ChatSoundState.length`).
    @ViewBuilder
    private var playerRow: some View {
        if player.holds(ref: note.ref, .chat) {
            ChatSoundProgress(progress: player.progress) { position, length in
                controls(ChatSoundState(
                    held: true,
                    playing: player.isPlaying,
                    position: position,
                    length: ChatSoundState.length(levels: levels, player: length, file: nil)
                ))
            }
        } else {
            controls(ChatSoundState(
                held: false,
                playing: false,
                position: 0,
                length: ChatSoundState.length(levels: levels, player: nil, file: nil)
            ))
        }
    }

    private func controls(_ state: ChatSoundState) -> ChatSoundControls {
        ChatSoundControls(
            name: ProductStrings[.chatVoiceNote],
            showsName: false,
            levels: levels,
            state: state,
            enabled: !player.callIsUp,
            toggle: { toggle(state) },
            seek: { player.seek(ref: note.ref, from: .chat, to: $0) }
        )
    }

    private func toggle(_ state: ChatSoundState) {
        guard state.playing else {
            Task { gone = await player.play(ref: note.ref, from: .chat) == .missing }
            return
        }

        player.pause()
    }

    /// Where the player would be: the waveform and the words, quiet.
    private var notAvailable: some View {
        Label(ProductStrings[.chatTileNotAvailable], systemImage: "waveform")
            .fermixType(Typography.style(.callout))
            .foregroundStyle(Palette.secondary.color)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ProductStrings[.chatVoiceNote])
            .accessibilityValue(ProductStrings[.chatTileNotAvailable])
    }
}
