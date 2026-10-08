import SwiftUI

/// What the call box shows, by the call's phase.
enum ChatCallBoxState: Equatable {
    /// From the click until the call's last frame: the pet and its dock,
    /// whose stop ends the call.
    case live
    /// The call ended: the still pet in its idle pose and the dock, whose
    /// stop is now Close, until the person closes it (owner, 2026-10-04). The
    /// box says nothing: the call's bill is the Pet page's.
    case ended
    /// The call, or the start of one, failed: the still pet, the dock's Close,
    /// and the one sentence the model kept for the failure, which carries the
    /// vendor's detail after it where the daemon sent one.
    case failed(String)

    /// Nothing with no call, which is where Close leaves an ended one.
    init?(voice: VoiceState) {
        switch voice.phase {
        case .idle:
            return nil
        case .starting, .active, .stopping:
            self = .live
        case .ended(.normal):
            self = .ended
        case .ended(.failed(_, let sentence)):
            self = .failed(sentence)
        }
    }
}

/// The call, floating at the top right of the chat body (M56; the owner's
/// direction of 2026-10-03).
///
/// It is the pet, as the floating window draws it (`PetCompanion`): the
/// mascot and the dock of its call controls, on the dock's own glass. The
/// mascot's animation is the call's status, so the box carries no status word,
/// no caption, no task and no cost: those are the Pet page's. The dock's stop
/// ends the call, and the box stays once it is over, the mascot still in its
/// idle pose, until the same control, then Close, puts it away (owner,
/// 2026-10-04); a failure keeps its sentence under the dock. The mascot's
/// click is the call control's, as on the floating window: it ends the call,
/// and on the idle pet it begins the next one.
///
/// It stands at the body's extreme right, in the margin a wide window leaves
/// beside the centred reading column, overlapping nothing; only where that
/// margin is narrower than the box does it reach over the transcript's
/// trailing edge (`overlapsColumn`). It takes no room in the column, so
/// nothing moves or docks when it comes and goes, and it is never a sheet or a
/// popover. It observes the call model itself: the chat surface only holds the
/// call, so a caption redraws the box and never the transcript. It has no
/// drag: it belongs to the chat, where the floating window belongs to the
/// desktop.
struct ChatCallBox: View {
    @ObservedObject var call: VoiceCallModel
    /// The call's façade, which the pet draws from and acts through.
    let pet: PetFeatureModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = ChatCallBoxState(voice: call.voice)

        ZStack {
            if let state {
                box(state)
                    .transition(.opacity)
            }
        }
        .animation(Motion(reduceMotion: reduceMotion).animation(.stepCrossfade), value: state)
    }

    // MARK: - The rules

    /// The mascot moves while a call is live, in a window on screen, and never
    /// under Reduce Motion; a new pose still lands while it is parked, which
    /// is how the idle pose reaches the box once the call is over.
    static func animates(live: Bool, windowVisible: Bool, reduceMotion: Bool) -> Bool {
        live && windowVisible && !reduceMotion
    }

    /// The two second intro, once per call: not again when the chat view is
    /// rebuilt mid-call, not for a failed call's still mascot, and never under
    /// Reduce Motion.
    static func playsIntro(live: Bool, introPlayed: Bool, reduceMotion: Bool) -> Bool {
        live && !introPlayed && !reduceMotion
    }

    /// Whether the box, at the body's top right with its inset, reaches over
    /// the reading column. The column is centred, and as wide as it is allowed
    /// or as the body less its gutters allows, so the margin beside it is half
    /// of what the body has left: the box stands clear wherever that margin
    /// holds the box and its inset. A matter of geometry, not of a breakpoint.
    static func overlapsColumn(box: Double, body: Double, column: Double, inset: Double) -> Bool {
        let drawn = min(column, body - 2 * ChatMetrics.columnGutter)
        let margin = (body - drawn) / 2

        return box + inset > margin
    }

    // MARK: - The drawing

    private func box(_ state: ChatCallBoxState) -> some View {
        let live = state == .live

        return VStack(spacing: Spacing.xs) {
            // A new start is a new mascot, so each call swells in once; the
            // call model remembers that it did, because this view is rebuilt on
            // every rail change.
            PetCompanion(
                model: pet,
                animates: Self.animates(live: live, windowVisible: call.mainWindowVisible, reduceMotion: reduceMotion),
                playsIntro: Self.playsIntro(live: live, introPlayed: call.introPlayed, reduceMotion: reduceMotion),
                // In every state the box has: the stop ends the call, then
                // closes the box, in one place.
                dock: .shown,
                host: .callBox
            )
            .id(call.voice.attempt)
            .onAppear { call.introShown() }

            if case .failed(let sentence) = state {
                // As wide as the pet's stage, so the box keeps the pet's width
                // whatever the sentence says.
                Text(sentence)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.ink.color)
                    .multilineTextAlignment(.center)
                    .frame(width: PetMetrics.stageSize.width)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.s)
        .frame(width: ChatMetrics.callBoxWidth)
        .background(.ultraThinMaterial, in: shape)
        .overlay(shape.strokeBorder(Palette.hairline(.standard).color, lineWidth: Stroke.hairline))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ChatMetrics.rowRadius, style: .continuous)
    }
}
