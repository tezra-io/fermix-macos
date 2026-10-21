import SwiftUI

/// What a sound's player shows, from the one player and the sound's own
/// length: pure, so its rules are provable without a view.
struct ChatSoundState: Equatable {
    /// Whether the player holds this sound now.
    let held: Bool
    let playing: Bool
    /// Where the held sound is; its start for one not held.
    let position: Double
    /// Its length, as `length(levels:player:file:)` chooses it; nil until
    /// one is known.
    let length: Double?

    /// The length a sound's row goes by: the one its levels decoded, once
    /// they are read, and AVFoundation's until then, the player's once it
    /// has read it before the file's. AVFoundation misreads the length of an
    /// Ogg Opus voice note (a 6.69 s note loads as 9.36 s, measured), which
    /// would run the time, the bars' fill, a click's or a drag's place and a
    /// step's end past the sound; the levels count the frames really decoded.
    static func length(levels: SoundLevels?, player: Double?, file: Double?) -> Double? {
        levels?.seconds ?? player ?? file
    }

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

    /// How much of the waveform is filled.
    var filled: Double {
        guard held, let length, length > 0 else { return 0 }

        return min(max(position / length, 0), 1)
    }

    /// Where a step lands, an arrow key's or VoiceOver's, held to the sound.
    func stepped(forward: Bool) -> Double {
        let target = position + (forward ? AppPlayer.step : -AppPlayer.step)

        return min(max(target, 0), length ?? .infinity)
    }

    /// Where a click or a drag at `fraction` of the waveform lands; nowhere
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
/// round play button, its name over its waveform, which fills as it plays
/// and which a click, a drag or the arrow keys move along, five seconds a
/// press, and the time, its length while it is still and where it is while
/// under way. Space plays and pauses from the button and the waveform alike.
/// Its levels are read while the row is on screen, through the chat's
/// previews, as a tile's preview is.
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
    /// The file's levels, once read.
    @State private var levels: SoundLevels?
    @State private var onScreen = false
    @Environment(\.chatRows) private var rows

    var body: some View {
        Group {
            if player.holds(url, .chat) {
                ChatSoundProgress(progress: player.progress) { position, length in
                    controls(ChatSoundState(
                        held: true,
                        playing: player.isPlaying,
                        position: position,
                        length: ChatSoundState.length(levels: levels, player: length, file: fileLength)
                    ))
                }
            } else {
                controls(ChatSoundState(
                    held: false,
                    playing: false,
                    position: 0,
                    length: ChatSoundState.length(levels: levels, player: nil, file: fileLength)
                ))
            }
        }
        .task(id: url) { fileLength = await player.facts.length(of: url) }
        .onScrollVisibilityChange(threshold: 0.01) { onScreen = $0 }
        .task(id: onScreen) {
            guard onScreen else { return }

            await readLevels()
        }
    }

    /// The file's levels, read where it really lands, and only inside the
    /// Fermix home, where a tile would draw what is in it. A file whose
    /// levels cannot be read keeps its resting bars, and still plays.
    private func readLevels() async {
        guard let rows, levels == nil,
              case .found(let facts) = await rows.media.lookUp(url, in: rows.visit), facts.insideHome
        else { return }

        let outcome = await rows.media.previews.levels(ChatLevelsRequest(facts))
        guard !Task.isCancelled, case .made(.levels(let read)) = outcome else { return }

        levels = read
    }

    private func controls(_ state: ChatSoundState) -> ChatSoundControls {
        ChatSoundControls(
            name: name,
            showsName: true,
            levels: levels,
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

/// The button, then the sound's waveform and time, drawn from one state: a
/// sound file's and a voice note's alike. A file's name is written over its
/// waveform, because the line that named the file is not in the reply's
/// text: the row is where it is said. A voice note's chip says what it is,
/// so its player is the one line, and its name is VoiceOver's.
struct ChatSoundControls: View {
    let name: String
    let showsName: Bool
    /// The sound's levels, nil until they are read.
    let levels: SoundLevels?
    let state: ChatSoundState
    /// False while a call is up, when nothing is offered.
    let enabled: Bool
    let toggle: () -> Void
    let seek: (Double) -> Void

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
                if showsName {
                    Text(name)
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.ink.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: Spacing.s) {
                    waveform
                        .frame(height: ChatMetrics.soundWaveHeight)
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

    private var waveform: ChatWaveform {
        ChatWaveform(levels: levels, filled: state.filled, playing: state.playing) { fraction in
            state.at(fraction).map(seek)
        }
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
