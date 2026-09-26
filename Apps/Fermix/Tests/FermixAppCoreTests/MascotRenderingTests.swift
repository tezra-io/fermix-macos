import Foundation
import SwiftUI
import Testing

@testable import FermixAppCore

/// The mascot is one Rive animation behind a seam, and the file and the code
/// agree on the names they share.
///
/// The renderer is not in this test target: it links the Rive runtime, which
/// only the GUI executable may (the same rule as Sparkle, M34 §6). So these
/// read the shipped file and the shipped sources.
@Suite("Mascot animation")
struct MascotAnimationTests {
    /// The renderer writes the pose by `PetExpression` raw value and the voice
    /// level by name. A file that renamed any of them would load and then sit
    /// in one pose for ever, so each name must be in the file the app ships.
    @Test("the shipped animation publishes every name the renderer writes")
    func animationPublishesTheNames() throws {
        let url = try #require(
            Bundle.module.url(forResource: MascotAnimation.fileName, withExtension: "riv"),
            "\(MascotAnimation.fileName).riv is not in the resource bundle"
        )
        let file = try Data(contentsOf: url)

        #expect(file.starts(with: Data("RIVE".utf8)), "the mascot file is not a Rive runtime file")

        let names = [MascotAnimation.stateMachine, MascotAnimation.modeProperty, MascotAnimation.levelProperty]
            + PetExpression.allCases.map(\.rawValue)
        for name in names {
            #expect(file.range(of: Data(name.utf8)) != nil, "the animation does not publish \(name)")
        }
    }

    /// The painted poses were retired with the animation. The two plates that
    /// remain in the tree are the one-ink mark's generator inputs and never
    /// ship.
    @Test("no painted pose ships in the bundle any more")
    func noPaintedPosesShip() throws {
        let images = Bundle.module.urls(forResourcesWithExtension: "png", subdirectory: nil) ?? []
        let poses = images.map(\.lastPathComponent).filter { $0.hasPrefix("pet_") }

        #expect(poses.isEmpty, "\(poses)")
    }

    /// Both executables link `FermixAppCore`, so an import there would put the
    /// runtime into `FermixAgent` as well.
    @Test("only the Rive adapter imports the runtime")
    func onlyTheAdapterImportsRive() throws {
        let importers = try SparkleAdapterSource.everySwiftFileUnderSources()
            .filter { $0.text.contains("import RiveRuntime") }

        #expect(!importers.isEmpty, "the scan found no file importing the Rive runtime at all")

        for file in importers {
            #expect(file.path.contains("/FermixRive/"), "\(file.path) imports the Rive runtime outside the adapter")
        }
    }

    /// The companion's click is the call. The animation publishes no listeners,
    /// and a view that took the click would swallow it before the tap below it
    /// saw it.
    @Test("the animation takes no click, so the mascot's click is the call")
    func animationTakesNoClick() throws {
        let adapter = try SparkleAdapterSource.everySwiftFileUnderSources()
            .filter { $0.path.contains("/FermixRive/") }

        #expect(!adapter.isEmpty, "the scan found no Rive adapter source at all")
        #expect(adapter.contains { $0.text.contains(".allowsHitTesting(false)") })

        let pet = try #require(try SourceTree.swiftFiles(matching: "Pet/PetView.swift").first?.text)
        #expect(pet.contains(".onTapGesture { model.toggleCall() }"))
    }
}

/// A renderer that draws nothing, for graphs that are built but never shown.
@MainActor
final class StillMascot: MascotRendering {
    func mascot(pose: PetExpression, level: @escaping @MainActor () -> Float, animates: Bool) -> AnyView {
        AnyView(EmptyView())
    }
}
