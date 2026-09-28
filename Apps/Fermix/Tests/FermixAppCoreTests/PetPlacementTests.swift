import CoreGraphics
import Testing
@testable import FermixAppCore

/// The floating pet hatches beside the app, never centred on a wide screen.
@Suite("Pet placement")
struct PetPlacementTests {
    private let pet = PetMetrics.windowSize
    /// A wide display's visible frame, as the owner's is.
    private let screen = CGRect(x: 0, y: 0, width: 3_840, height: 1_055)

    @Test("beside the window's bottom-right corner, outside it")
    func besideTheRightCorner() {
        let primary = CGRect(x: 767, y: 112, width: 1_156, height: 796)

        let frame = PetPlacement.frame(size: pet, beside: primary, within: screen)

        #expect(frame == CGRect(origin: CGPoint(x: primary.maxX, y: primary.minY), size: pet))
    }

    @Test("on the window's left when the right side has no room")
    func leftWhenTheRightIsFull() {
        let primary = CGRect(x: 2_700, y: 112, width: 1_140, height: 796)

        let frame = PetPlacement.frame(size: pet, beside: primary, within: screen)

        #expect(frame == CGRect(origin: CGPoint(x: primary.minX - pet.width, y: primary.minY), size: pet))
    }

    @Test("over the window's own corner when it fills the screen")
    func insideWhenNeitherSideHasRoom() {
        let frame = PetPlacement.frame(size: pet, beside: screen, within: screen)

        #expect(frame == CGRect(origin: CGPoint(x: screen.maxX - pet.width, y: screen.minY), size: pet))
    }

    @Test("a window reaching below the visible frame puts the pet on the visible bottom")
    func bottomHeldOnScreen() {
        let primary = CGRect(x: 767, y: -40, width: 1_156, height: 796)

        let frame = PetPlacement.frame(size: pet, beside: primary, within: screen)

        #expect(frame.minY == screen.minY)
        #expect(screen.contains(frame))
    }

    @Test("with no primary window, the screen's bottom-right corner")
    func screenCornerWithoutAWindow() {
        let frame = PetPlacement.frame(size: pet, beside: nil, within: screen)

        #expect(frame == CGRect(origin: CGPoint(x: screen.maxX - pet.width, y: screen.minY), size: pet))
    }
}
