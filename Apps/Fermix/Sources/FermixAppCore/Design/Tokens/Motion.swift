import SwiftUI

/// Product motion and its supporting timings (`M34_DESIGN_SYSTEM_REDLINES.md` §6).
public enum MotionRole: String, CaseIterable, Sendable {
    case windowEnter
    case glyphPulse
    case stepCrossfade
    case mascotEntrance
    case riseIn

    /// Whether SwiftUI drives this role.
    ///
    /// One does not, and no longer moves at all: the menu-bar glyph is an
    /// `NSStatusItem` template image the system draws, so the starting state is
    /// a lighter raster baked from `MenuBarGlyphInk.startingOpacity` rather
    /// than an animation. The role stays in the table because the table is the
    /// redline's record. Every other role must reach a view, and the build gate
    /// says so.
    public var renderedBySwiftUI: Bool { self != .glyphPulse }
}

/// What kind of motion a role is. Reduce Motion resolves by kind, so the rule
/// is one switch rather than a `reduceMotion` branch at every call site.
public enum MotionKind: String, CaseIterable, Sendable {
    /// Runs forever. Holds at its high value when suppressed.
    case loop
    /// Brings a surface in. Becomes opacity-only when suppressed.
    case entrance
    /// Fires once on a moment. Skipped when suppressed.
    case oneShot
    /// Swaps one step for another. Loses its slide when suppressed.
    case crossfade
}

/// One animation constant: the SwiftUI curve and duration, plus the artboard's
/// own published duration so drift from the redline is visible.
public struct MotionSpec: Equatable, Sendable {
    public enum Curve: Equatable, Sendable {
        case easeInOut
        case easeOut
        case ease
        case spring(response: Double, dampingFraction: Double)
        case timingCurve(Double, Double, Double, Double)
    }

    public let curve: Curve
    /// Seconds, as SwiftUI runs it. An autoreversing loop runs one half-cycle
    /// per `duration`.
    public let duration: Double
    public let repeatsForever: Bool
    public let autoreverses: Bool
    /// The artboard's published duration, in milliseconds.
    public let redlineMilliseconds: Double

    public init(
        curve: Curve,
        duration: Double,
        repeatsForever: Bool = false,
        autoreverses: Bool = false,
        redlineMilliseconds: Double
    ) {
        precondition(duration > 0, "motion duration must be positive")
        precondition(redlineMilliseconds > 0, "redline duration must be positive")

        self.curve = curve
        self.duration = duration
        self.repeatsForever = repeatsForever
        self.autoreverses = autoreverses
        self.redlineMilliseconds = redlineMilliseconds
    }

    public var animation: Animation {
        let base: Animation

        switch curve {
        case .easeInOut: base = .easeInOut(duration: duration)
        case .easeOut: base = .easeOut(duration: duration)
        case .ease: base = .easeInOut(duration: duration)
        case .spring(let response, let dampingFraction):
            base = .spring(response: response, dampingFraction: dampingFraction)
        case .timingCurve(let c0, let c1, let c2, let c3):
            base = .timingCurve(c0, c1, c2, c3, duration: duration)
        }

        return repeatsForever ? base.repeatForever(autoreverses: autoreverses) : base
    }
}

/// The stagger tables the artboards publish, in seconds.
public enum MotionStagger {
    /// Welcome's ladder (§5.1), which is the one §6 publishes as the default.
    public static let riseIn: [Double] = [0.12, 0.20, 0.30, 0.38]
    /// Ready's ladder (§5.5): its first two blocks arrive slightly later.
    public static let readyRiseIn: [Double] = [0.15, 0.22, 0.30, 0.38]
    /// The delay for the nth block of a published ladder.
    ///
    /// A surface asks for the step it is drawing rather than indexing the array,
    /// because a screen with more blocks than the ladder would otherwise trap.
    /// Past the end the last delay holds: the ladder has run out, and the
    /// remaining blocks arrive with the final one.
    public static func delay(_ step: Int, in ladder: [Double]) -> Double {
        precondition(!ladder.isEmpty, "a stagger ladder needs at least one delay")
        guard step > 0 else { return ladder[0] }

        return ladder[min(step, ladder.count - 1)]
    }

    public static func riseInDelay(_ step: Int) -> Double {
        delay(step, in: riseIn)
    }
}

/// The travel an entrance covers, in points (`Main.dc.html`'s `rise-in`
/// keyframe and `DESIGN_SPEC` §7's window enter).
public enum MotionEntrance {
    /// `from { opacity: 0; transform: translateY(14px) }`.
    public static let riseInOffset: Double = 14
    public static let windowEnterOffset: Double = 14
    public static let windowEnterScale: Double = 0.985

    /// How far the role travels. §6 makes a suppressed entrance opacity-only,
    /// so the travel goes to zero rather than each view branching on the
    /// environment itself.
    public static func offset(for role: MotionRole, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 0 }

        switch role {
        case .riseIn: return riseInOffset
        case .windowEnter: return windowEnterOffset
        default: return 0
        }
    }

    public static func scale(for role: MotionRole, reduceMotion: Bool) -> Double {
        guard !reduceMotion, role == .windowEnter else { return 1 }

        return windowEnterScale
    }

    /// A stagger delay, dropped with the travel: a choreographed entrance that
    /// still arrives block by block is the motion Reduce Motion asked to lose.
    public static func delay(_ seconds: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : seconds
    }
}

/// The motion constants table, at full motion.
public enum MotionTable {
    public static func spec(_ role: MotionRole) -> MotionSpec {
        switch role {
        case .windowEnter:
            return MotionSpec(curve: .spring(response: 0.28, dampingFraction: 0.85), duration: 0.28, redlineMilliseconds: 280)
        case .glyphPulse:
            return MotionSpec(curve: .easeInOut, duration: 0.8, repeatsForever: true, autoreverses: true, redlineMilliseconds: 1600)
        case .stepCrossfade:
            return MotionSpec(curve: .ease, duration: 0.24, redlineMilliseconds: 240)
        case .mascotEntrance:
            return MotionSpec(curve: .timingCurve(0.34, 1.4, 0.64, 1), duration: 0.7, redlineMilliseconds: 700)
        case .riseIn:
            return MotionSpec(curve: .timingCurve(0.32, 0.72, 0, 1), duration: 0.48, redlineMilliseconds: 480)
        }
    }

    public static func kind(_ role: MotionRole) -> MotionKind {
        switch role {
        case .glyphPulse:
            return .loop
        case .windowEnter, .mascotEntrance, .riseIn:
            return .entrance
        case .stepCrossfade:
            return .crossfade
        }
    }
}

/// The one place Reduce Motion is resolved.
///
/// Every call site asks this type for its animation instead of branching on
/// the environment itself, so the accessibility rule lives in one switch. No
/// state is conveyed by motion alone: a suppressed loop holds at its high
/// value, and every ladder row, menu-bar state, and success state has a text
/// or shape equivalent.
public struct Motion: Sendable {
    public let reduceMotion: Bool

    public init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
    }

    /// The spec to run, or nil when the role must not animate at all.
    public func resolved(_ role: MotionRole) -> MotionSpec? {
        guard reduceMotion else { return MotionTable.spec(role) }

        switch MotionTable.kind(role) {
        case .loop, .oneShot:
            return nil
        case .entrance, .crossfade:
            return Self.reducedEntrance
        }
    }

    public func animation(_ role: MotionRole) -> Animation? {
        resolved(role)?.animation
    }

    public func isSuppressed(_ role: MotionRole) -> Bool {
        resolved(role) == nil
    }

    /// Where a suppressed loop parks. 1 is the high value, so the menu-bar
    /// glyph keeps its full opacity.
    public func restingProgress(_ role: MotionRole) -> Double {
        guard reduceMotion, MotionTable.kind(role) == .loop else { return 0 }

        return 1
    }

    /// Step to step. The slide is the part Reduce Motion drops; the window
    /// itself never moves on either path.
    public func stepTransition() -> AnyTransition {
        guard !reduceMotion else { return .opacity }

        return .asymmetric(
            insertion: .offset(x: 16).combined(with: .opacity),
            removal: .offset(x: -16).combined(with: .opacity)
        )
    }

    /// §6: entrances become opacity-only at 150ms.
    static let reducedEntrance = MotionSpec(curve: .easeOut, duration: 0.15, redlineMilliseconds: 150)
}

/// The menu-bar glyph's starting state, as the shipped raster carries it.
///
/// The glyph is an `NSStatusItem` template image the system draws, and the
/// status item does not animate: `scripts/build_menu_bar_template.py` bakes
/// this fraction into the starting raster, so the redline's opacity floor (§6)
/// is spent as a static lighter ink rather than as the trough of a pulse. That
/// is what makes the state readable under Reduce Motion without a second
/// rendering, and it is why there is no period and no elapsed time anywhere
/// here: ink is all that is left of that animation.
public enum MenuBarGlyphInk {
    /// The starting state's ink, as a fraction of the running state's.
    public static let startingOpacity: Double = 0.45
}
