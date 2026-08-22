import Foundation
import Testing

@testable import FermixAppCore

/// The six named animations plus their supporting timings, and the one rule
/// that resolves them under Reduce Motion
/// (`M34_DESIGN_SYSTEM_REDLINES.md` §6).
@Suite("Design motion")
struct DesignMotionTests {
    @Test("the six named animations carry their published redline durations")
    func namedAnimations() {
        #expect(MotionTable.spec(.orbBreath).redlineMilliseconds == 2800)
        #expect(MotionTable.spec(.orbBreath).curve == .easeInOut)
        #expect(MotionTable.spec(.orbBreath).duration == 1.4)
        #expect(MotionTable.spec(.orbBreath).repeatsForever)
        #expect(MotionTable.spec(.orbBreath).autoreverses)

        #expect(MotionTable.spec(.stageAdvance).redlineMilliseconds == 320)
        #expect(MotionTable.spec(.stageAdvance).curve == .spring(response: 0.32, dampingFraction: 0.62))

        #expect(MotionTable.spec(.windowEnter).redlineMilliseconds == 280)
        #expect(MotionTable.spec(.windowEnter).curve == .spring(response: 0.28, dampingFraction: 0.85))

        #expect(MotionTable.spec(.successBloom).redlineMilliseconds == 900)
        #expect(MotionTable.spec(.successBloom).curve == .easeOut)
        #expect(MotionTable.spec(.successBloom).duration == 0.9)
        #expect(!MotionTable.spec(.successBloom).repeatsForever)

        #expect(MotionTable.spec(.glyphPulse).redlineMilliseconds == 1600)
        #expect(MotionTable.spec(.glyphPulse).repeatsForever)

        #expect(MotionTable.spec(.stepCrossfade).redlineMilliseconds == 240)
        #expect(MotionTable.spec(.stepCrossfade).curve == .ease)
    }

    @Test("the supporting timings carry their published redline durations")
    func supportingTimings() {
        #expect(MotionTable.spec(.ladderSpinner).redlineMilliseconds == 900)
        #expect(MotionTable.spec(.ladderSpinner).curve == .linear)
        #expect(!MotionTable.spec(.ladderSpinner).autoreverses)

        #expect(MotionTable.spec(.sheenSweep).redlineMilliseconds == 2200)
        #expect(MotionTable.spec(.mascotEntrance).redlineMilliseconds == 700)
        #expect(MotionTable.spec(.mascotEntrance).curve == .timingCurve(0.34, 1.4, 0.64, 1))
        #expect(MotionTable.spec(.riseIn).redlineMilliseconds == 480)
        #expect(MotionTable.spec(.riseIn).curve == .timingCurve(0.32, 0.72, 0, 1))
        #expect(MotionTable.spec(.blobDriftA).redlineMilliseconds == 18000)
        #expect(MotionTable.spec(.blobDriftB).redlineMilliseconds == 22000)
    }

    @Test("the rise-in and bloom staggers match the redline")
    func staggers() {
        #expect(MotionStagger.riseIn == [0.12, 0.20, 0.30, 0.38])
        #expect(MotionStagger.successBloom == [0.20, 0.38])
    }

    @Test("every role is classified, so a role added later must pick a kind")
    func everyRoleHasAKind() {
        for role in MotionRole.allCases {
            #expect(MotionTable.spec(role).redlineMilliseconds > 0, "\(role)")
            _ = MotionTable.kind(role)
        }
    }

    @Test("full motion resolves every role to its table spec")
    func fullMotionUsesTheTable() {
        let motion = Motion(reduceMotion: false)

        for role in MotionRole.allCases {
            #expect(motion.resolved(role) == MotionTable.spec(role), "\(role)")
            #expect(motion.animation(role) != nil, "\(role)")
        }
    }

    @Test("reduce motion suppresses every loop and every one-shot")
    func reduceMotionSuppressesLoops() {
        let motion = Motion(reduceMotion: true)

        for role in MotionRole.allCases where MotionTable.kind(role) == .loop || MotionTable.kind(role) == .oneShot {
            #expect(motion.resolved(role) == nil, "\(role)")
            #expect(motion.animation(role) == nil, "\(role)")
            #expect(motion.isSuppressed(role), "\(role)")
        }
    }

    @Test("reduce motion turns every entrance and crossfade into 150ms opacity")
    func reduceMotionShortensEntrances() {
        let motion = Motion(reduceMotion: true)

        for role in MotionRole.allCases where MotionTable.kind(role) == .entrance || MotionTable.kind(role) == .crossfade {
            let resolved = motion.resolved(role)

            #expect(resolved?.duration == 0.15, "\(role)")
            #expect(resolved?.curve == .easeOut, "\(role)")
            #expect(resolved?.repeatsForever == false, "\(role)")
        }
    }

    @Test("reduce motion makes a state change instant rather than springy")
    func reduceMotionMakesStateChangesInstant() {
        #expect(Motion(reduceMotion: true).resolved(.stageAdvance) == nil)
    }

    /// The menu-bar glyph is an `NSStatusItem` image, so its pulse is computed
    /// from elapsed time rather than driven by a SwiftUI animation.
    @Test("the glyph pulse sweeps the published opacity range on its period")
    func glyphPulseOpacity() {
        #expect(MenuBarGlyphPulse.period == 1.6)
        #expect(MenuBarGlyphPulse.minimumOpacity == 0.45)
        #expect(MenuBarGlyphPulse.maximumOpacity == 1)

        #expect(MenuBarGlyphPulse.opacity(atElapsed: 0, reduceMotion: false) == 0.45)
        #expect(abs(MenuBarGlyphPulse.opacity(atElapsed: 0.8, reduceMotion: false) - 1) < 0.0001)
        #expect(abs(MenuBarGlyphPulse.opacity(atElapsed: 1.6, reduceMotion: false) - 0.45) < 0.0001)
        #expect(abs(MenuBarGlyphPulse.opacity(atElapsed: 4.0, reduceMotion: false) - 1) < 0.0001)
    }

    @Test("reduce motion holds the glyph at full opacity")
    func glyphPulseHoldsUnderReduceMotion() {
        for elapsed in [0.0, 0.4, 0.8, 1.2, 1.6] {
            #expect(MenuBarGlyphPulse.opacity(atElapsed: elapsed, reduceMotion: true) == 1)
        }
    }

    /// No state may be conveyed by motion alone: every role that reports a
    /// resting value must hold at the value that reads as "present".
    @Test("suppressed loops hold at their high value")
    func loopsHoldAtRest() {
        let motion = Motion(reduceMotion: true)

        #expect(motion.restingProgress(.orbBreath) == 1)
        #expect(motion.restingProgress(.glyphPulse) == 1)
        #expect(Motion(reduceMotion: false).restingProgress(.orbBreath) == 0)
    }

    /// The `rise-in` keyframe the artboards publish:
    /// `from { opacity: 0; transform: translateY(14px) }`.
    @Test("rise-in enters from 14 points below at zero opacity")
    func riseInGeometry() {
        #expect(MotionEntrance.riseInOffset == 14)
        #expect(MotionEntrance.windowEnterOffset == 14)
        #expect(MotionEntrance.windowEnterScale == 0.985)
    }

    /// The stagger table is a ladder, so a surface asks for the delay of the
    /// block it is drawing rather than indexing an array that may be shorter
    /// than the number of blocks on screen.
    @Test("a stagger step past the published ladder holds at its last delay")
    func riseInStaggerIsBounded() {
        #expect(MotionStagger.riseInDelay(0) == 0.12)
        #expect(MotionStagger.riseInDelay(3) == 0.38)
        #expect(MotionStagger.riseInDelay(9) == 0.38)
        #expect(MotionStagger.riseInDelay(-1) == 0.12)
    }

    /// Reduce Motion keeps the entrance but drops its travel: §6 makes an
    /// entrance opacity-only, so no block may still slide.
    @Test("reduce motion drops the entrance travel and the stagger with it")
    func reducedEntranceHasNoTravel() {
        #expect(MotionEntrance.offset(for: .riseIn, reduceMotion: true) == 0)
        #expect(MotionEntrance.offset(for: .riseIn, reduceMotion: false) == 14)
        #expect(MotionEntrance.delay(0.30, reduceMotion: true) == 0)
        #expect(MotionEntrance.delay(0.30, reduceMotion: false) == 0.30)
    }
}

/// The motion table is only worth its constants if the product applies them.
///
/// This scans the shipped sources for a call site per role, deriving its case
/// set from `MotionRole.allCases` rather than from a hand-kept list, so a role
/// added later either gets applied or fails here.
@Suite("Motion application")
struct MotionApplicationTests {
    @Test("every SwiftUI-rendered role is applied at a call site outside the table")
    func everyRoleIsApplied() throws {
        let sources = try SourceTree.swiftFiles(under: "Design/Tokens/Motion.swift", excluding: true)

        for role in MotionRole.allCases where role.renderedBySwiftUI {
            let applied = sources.contains { $0.text.contains(".\(role.rawValue)") }

            #expect(applied, "\(role.rawValue) is declared but never applied")
        }
    }

    /// The one role SwiftUI cannot drive: an `NSStatusItem` image is redrawn
    /// from elapsed time, so its constants live in `MenuBarGlyphPulse`.
    @Test("the timer-driven role is the glyph pulse and nothing else")
    func timerDrivenRoles() {
        let timerDriven = MotionRole.allCases.filter { !$0.renderedBySwiftUI }

        #expect(timerDriven == [.glyphPulse])
        #expect(MenuBarGlyphPulse.period == MotionTable.spec(.glyphPulse).redlineMilliseconds / 1000)
    }

    /// A role reaching one shared modifier is only half the invariant: the
    /// modifier itself has to be applied by a surface. This derives its case set
    /// from the declarations in the sources, so a modifier added later either
    /// gets used or fails here.
    @Test("every view modifier the design system publishes has a call site")
    func everyPublishedModifierIsApplied() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
        let declarations = files.flatMap { file in
            SourceTree.declaredViewModifiers(in: file.text).map { (name: $0, path: file.path) }
        }

        #expect(!declarations.isEmpty, "no design-system modifiers were found to check")
        for declaration in declarations {
            let applied = files.contains {
                $0.path != declaration.path && $0.text.contains(".\(declaration.name)(")
            }

            #expect(applied, "\(declaration.name) is published but no surface applies it")
        }
    }

    /// Welcome and Ready are the two screens the redline choreographs, so both
    /// have to arrive block by block rather than as one flat pop.
    @Test("the two choreographed surfaces bring their blocks in on a ladder")
    func choreographedSurfacesStagger() throws {
        for name in ["Onboarding/OnboardingWindowView.swift", "Onboarding/ReadySurface.swift"] {
            let surface = try SourceTree.swiftFiles(matching: name)

            #expect(surface.count == 1, "\(name)")
            #expect(surface.first?.text.contains("fermixRiseIn(") == true, "\(name) reveals every block at once")
        }
    }
}
