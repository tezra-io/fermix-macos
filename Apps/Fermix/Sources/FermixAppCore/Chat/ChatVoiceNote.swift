import SwiftUI

/// A voice note from the phone (M66 §3.4): a chip on its row's side in the
/// chip's fill, as the phone draws one, with its player, drawn as a sound's
/// is (play, a track, the time) and named "Voice note", and the transcript,
/// the row's text, under it. A note with no transcript, one still being
/// transcribed or one that could not be, is the player alone.
///
/// It plays on the app's one player from the file the engine grants for the
/// note when play is pressed, and the player keeps that grant for as long as
/// it holds the note (`AppPlayer.play(ref:from:)`). A note whose bytes the
/// engine no longer has shows Not available where the player would be, with
/// its transcript still under it.
struct ChatVoiceNote: View {
    let note: CompanionMediaRef
    let transcript: AttributedString
    /// Who sent it, which side it is drawn on and how VoiceOver names its
    /// transcript.
    let speaker: String?
    @ObservedObject var player: AppPlayer

    /// Whether the engine said, when play was last pressed, that it no
    /// longer has the note's bytes.
    @State private var gone = false

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
    }

    /// The player, its place observed only while the one player holds this
    /// note, so a tick redraws this chip and no other. Its length is the
    /// player's, read once the note is first played.
    @ViewBuilder
    private var playerRow: some View {
        if player.holds(ref: note.ref, .chat) {
            ChatSoundProgress(progress: player.progress) { position, length in
                controls(ChatSoundState(held: true, playing: player.isPlaying, position: position, length: length))
            }
        } else {
            controls(ChatSoundState(held: false, playing: false, position: 0, length: nil))
        }
    }

    private func controls(_ state: ChatSoundState) -> ChatSoundControls {
        ChatSoundControls(
            name: ProductStrings[.chatVoiceNote],
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
