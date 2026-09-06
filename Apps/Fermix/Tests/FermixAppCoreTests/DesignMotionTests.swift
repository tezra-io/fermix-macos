import Foundation
import Testing

@testable import FermixAppCore

/// The named animations plus their supporting timings, and the one rule
/// that resolves them under Reduce Motion
/// (`M34_DESIGN_SYSTEM_REDLINES.md` §6).
@Suite("Design motion")
struct DesignMotionTests {
    @Test("the named animations carry their published redline durations")
    func namedAnimations() {
        #expect(MotionTable.spec(.windowEnter).redlineMilliseconds == 280)
        #expect(MotionTable.spec(.windowEnter).curve == .spring(response: 0.28, dampingFraction: 0.85))

        #expect(MotionTable.spec(.glyphPulse).redlineMilliseconds == 1600)
        #expect(MotionTable.spec(.glyphPulse).repeatsForever)

        #expect(MotionTable.spec(.stepCrossfade).redlineMilliseconds == 240)
        #expect(MotionTable.spec(.stepCrossfade).curve == .ease)
    }

    @Test("the supporting timings carry their published redline durations")
    func supportingTimings() {
        #expect(MotionTable.spec(.mascotEntrance).redlineMilliseconds == 700)
        #expect(MotionTable.spec(.mascotEntrance).curve == .timingCurve(0.34, 1.4, 0.64, 1))
        #expect(MotionTable.spec(.riseIn).redlineMilliseconds == 480)
        #expect(MotionTable.spec(.riseIn).curve == .timingCurve(0.32, 0.72, 0, 1))
    }

    /// The success bloom died with the Ready mascot, so its binding is gone
    /// from the role table entirely: the remaining roles are the whole set.
    @Test("the rise-in staggers match the redline, and the bloom is gone")
    func staggers() {
        #expect(MotionStagger.riseIn == [0.12, 0.20, 0.30, 0.38])
        #expect(MotionStagger.readyRiseIn == [0.15, 0.22, 0.30, 0.38])
        #expect(!MotionRole.allCases.map(\.rawValue).contains("successBloom"))
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

    /// The menu-bar glyph is an `NSStatusItem` image the system draws, and it
    /// does not animate: the redline's opacity floor is baked into the starting
    /// raster instead, which is what makes the state readable under Reduce
    /// Motion without a second rendering. One constant survives that, because
    /// it is the ink the shipped raster is asserted against.
    @Test("the glyph publishes one ink and nothing that moves")
    func glyphInk() {
        #expect(MenuBarGlyphInk.startingOpacity == 0.45)
    }

    /// No state may be conveyed by motion alone: every role that reports a
    /// resting value must hold at the value that reads as "present".
    @Test("suppressed loops hold at their high value")
    func loopsHoldAtRest() {
        let motion = Motion(reduceMotion: true)

        #expect(motion.restingProgress(.glyphPulse) == 1)
        #expect(Motion(reduceMotion: false).restingProgress(.glyphPulse) == 0)
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

    /// The one role no view renders: an `NSStatusItem` image is drawn by the
    /// system, so the glyph's states are rasters and the ink the starting one
    /// is baked at lives in `MenuBarGlyphInk`. The row stays in the table
    /// because the table is the redline's record, and this is what keeps the
    /// exemption to exactly one and the row itself honest.
    @Test("the glyph is the one role outside SwiftUI, and nothing else is")
    func rolesOutsideSwiftUI() {
        let outside = MotionRole.allCases.filter { !$0.renderedBySwiftUI }

        #expect(outside == [.glyphPulse])
        #expect(MotionTable.spec(.glyphPulse).redlineMilliseconds == 1600)
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
