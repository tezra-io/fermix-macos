import SwiftUI

/// What a sound's player shows, from the one player and the file's own
/// length: pure, so its rules are provable without a view.
struct ChatSoundState: Equatable {
    /// Whether the player holds this sound now.
    let held: Bool
    let playing: Bool
    /// Where the held sound is; its start for one not held.
    let position: Double
    /// Its length: the player's once it has read it, the file's before it;
    /// nil until either is known.
    let length: Double?

    /// Under way: playing, or paused past its start. A sound that played to
    /// its end is back at its start, still.
    var underWay: Bool {
        held && (playing || position > 0)
    }

    /// The time shown: where it is while under way, and its length while it
    /// is still; nil while its length is not known yet.
    var shownTime: Double? {
        underWay ? position : length
    }

    /// How much of the track is filled.
    var filled: Double {
        guard held, let length, length > 0 else { return 0 }

        return min(max(position / length, 0), 1)
    }

    /// Where a step lands, an arrow key's or VoiceOver's, held to the sound.
    func stepped(forward: Bool) -> Double {
        let target = position + (forward ? AppPlayer.step : -AppPlayer.step)

        return min(max(target, 0), length ?? .infinity)
    }

    /// Where a click or a drag at `fraction` of the track lands; nowhere
    /// until the sound's length is known.
    func at(_ fraction: Double) -> Double? {
        length.map { $0 * min(max(fraction, 0), 1) }
    }

    /// A time as the player writes it, with the hours only where it has any.
    static func written(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: seconds < 3600 ? .minuteSecond : .hourMinuteSecond))
    }

    /// A time as VoiceOver says it, in words.
    static func spoken(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

/// A sound file inside the Fermix home, played where it is (M66 §3.4): a
/// round play button, a thin track that fills as it plays and that a click,
/// a drag or the arrow keys move along, five seconds a press, and the time,
/// its length while it is still and where it is while under way. Space
/// plays and pauses from the button and the track alike.
///
/// It plays on the app's one player, so starting it stops whatever was
/// playing, it keeps playing when its row scrolls away and shows it when the
/// row comes back, and nothing is offered while a call is up. To VoiceOver it
/// is one adjustable element, named by the file and valued by its time, with
/// Play or Pause as its action.
struct ChatSoundRow: View {
    let url: URL
    let name: String
    @ObservedObject var player: AppPlayer

    /// The file's own length, read once the row is on screen.
    @State private var fileLength: Double?

    var body: some View {
        Group {
            if player.holds(url, .chat) {
                ChatSoundProgress(progress: player.progress) { position, length in
                    controls(ChatSoundState(held: true, playing: player.isPlaying, position: position, length: length ?? fileLength))
                }
            } else {
                controls(ChatSoundState(held: false, playing: false, position: 0, length: fileLength))
            }
        }
        .task(id: url) { fileLength = await player.facts.length(of: url) }
    }

    private func controls(_ state: ChatSoundState) -> ChatSoundControls {
        ChatSoundControls(
            name: name,
            state: state,
            enabled: !player.callIsUp,
            toggle: { toggle(state) },
            seek: { player.seek(url, from: .chat, to: $0) }
        )
    }

    private func toggle(_ state: ChatSoundState) {
        guard state.playing else {
            player.play(url, from: .chat)
            return
        }

        player.pause()
    }
}

/// The held sound's place, observed by the one row that holds it alone, so a
/// tick redraws that row and no other.
struct ChatSoundProgress: View {
    @ObservedObject var progress: AppPlayerProgress
    let content: (Double, Double?) -> ChatSoundControls

    var body: some View {
        content(progress.position, progress.length)
    }
}

/// The button, then the sound's name over its track and time, drawn from one
/// state: a sound file's and a voice note's alike. The name is on the row
/// because the line that named the file is not in the reply's text: the row
/// is where it is said.
struct ChatSoundControls: View {
    let name: String
    let state: ChatSoundState
    /// False while a call is up, when nothing is offered.
    let enabled: Bool
    let toggle: () -> Void
    let seek: (Double) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragging = false

    var body: some View {
        HStack(spacing: Spacing.s) {
            Button(action: toggle) {
                Image(systemName: state.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: ChatMetrics.soundGlyph, weight: .semibold))
                    .offset(x: state.playing ? 0 : ChatMetrics.soundPlayGlyphNudge)
                    .frame(width: ChatMetrics.soundButton, height: ChatMetrics.soundButton)
            }
            .buttonStyle(ChatSoundButtonStyle())
            .accessibilityLabel(ProductStrings[action])

            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.ink.color)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: Spacing.s) {
                    track
                        .frame(height: ChatMetrics.soundTrackHitHeight)
                        .opacity(enabled ? 1 : ButtonRecipe.disabledOpacity)
                        .focusable(enabled)
                        .onKeyPress(.leftArrow) { step(forward: false) }
                        .onKeyPress(.rightArrow) { step(forward: true) }
                        .onKeyPress(.space) {
                            toggle()
                            return .handled
                        }

                    Text(state.shownTime.map(ChatSoundState.written) ?? "")
                        .fermixType(Typography.style(.caption))
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondary.color)
                }
            }
        }
        .frame(maxWidth: ChatMetrics.soundMaxWidth, alignment: .leading)
        .disabled(!enabled)
        .help(name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(state.shownTime.map(ChatSoundState.spoken) ?? "")
        .accessibilityAdjustableAction { direction in seek(state.stepped(forward: direction == .increment)) }
        .accessibilityAction(named: ProductStrings[action], toggle)
    }

    private var action: ProductStringKey {
        state.playing ? .mediaPause : .mediaPlay
    }

    /// A thin line on the ground, filled in ink as far as the sound has
    /// played. While it plays the fill moves over each tick rather than
    /// jumping, except under Reduce Motion and under the pointer.
    private var track: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline(.strong).color)
                Capsule().fill(Palette.ink.color)
                    .frame(width: proxy.size.width * state.filled)
            }
            .frame(height: ChatMetrics.soundTrackHeight)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, dragging, _ in dragging = true }
                    .onChanged { drag in
                        guard proxy.size.width > 0, let target = state.at(drag.location.x / proxy.size.width) else { return }

                        seek(target)
                    }
            )
        }
        .animation(moves ? .linear(duration: AppPlayer.tick) : nil, value: state.filled)
    }

    private var moves: Bool {
        state.playing && !dragging && !reduceMotion
    }

    private func step(forward: Bool) -> KeyPress.Result {
        seek(state.stepped(forward: forward))
        return .handled
    }
}

/// The play button: a circle in the secondary capsule's own fill, hairline
/// and ink, which is the capsule at equal width and height.
private struct ChatSoundButtonStyle: ButtonStyle {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ButtonRecipe.secondaryLabel.color)
            .background(Circle().fill((configuration.isPressed ? Palette.base300 : ButtonRecipe.secondaryFill).color))
            .overlay(
                Circle().strokeBorder(
                    contrast == .increased
                        ? Palette.hairline(.standard, increaseContrast: true).color
                        : ButtonRecipe.secondaryBorder.color,
                    lineWidth: Stroke.hairline
                )
            )
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : ButtonRecipe.disabledOpacity)
    }
}
