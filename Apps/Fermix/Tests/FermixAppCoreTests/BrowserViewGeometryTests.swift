import CoreGraphics
import Foundation
import Testing

@testable import FermixAppCore

/// Where a page's layout-viewport point lands in the web view, which is what
/// a click or a hover is delivered at.
@Suite("Browser view geometry")
struct BrowserViewGeometryTests {
    static let identityViewport = BrowserVisualViewport()

    @Test("an unzoomed, unscrolled flipped view maps a point one to one")
    func identityFlipped() {
        let geometry = BrowserViewGeometry(size: CGSize(width: 800, height: 600), isFlipped: true, pageZoom: 1)

        let point = geometry.viewPoint(x: 100, y: 50, viewport: Self.identityViewport)

        #expect(point == CGPoint(x: 100, y: 50))
    }

    @Test("an unflipped view counts y from the bottom")
    func unflippedCountsFromTheBottom() {
        let geometry = BrowserViewGeometry(size: CGSize(width: 800, height: 600), isFlipped: false, pageZoom: 1)

        let point = geometry.viewPoint(x: 100, y: 50, viewport: Self.identityViewport)

        #expect(point == CGPoint(x: 100, y: 550))
    }

    @Test("the page zoom scales a CSS-pixel point into view points")
    func pageZoomScales() {
        let geometry = BrowserViewGeometry(size: CGSize(width: 800, height: 600), isFlipped: true, pageZoom: 2)

        let point = geometry.viewPoint(x: 100, y: 50, viewport: Self.identityViewport)

        #expect(point == CGPoint(x: 200, y: 100))
    }

    @Test("the visual viewport's own scale multiplies the page zoom")
    func visualViewportScaleMultiplies() {
        let geometry = BrowserViewGeometry(size: CGSize(width: 800, height: 600), isFlipped: true, pageZoom: 1)
        let viewport = BrowserVisualViewport(offsetLeft: 0, offsetTop: 0, scale: 2)

        let point = geometry.viewPoint(x: 100, y: 50, viewport: viewport)

        #expect(point == CGPoint(x: 200, y: 100))
    }

    @Test("the visual viewport's offset is measured from the visible part's corner")
    func visualViewportOffsetIsSubtracted() {
        let geometry = BrowserViewGeometry(size: CGSize(width: 800, height: 600), isFlipped: true, pageZoom: 1)
        let viewport = BrowserVisualViewport(offsetLeft: 20, offsetTop: 10, scale: 1)

        let point = geometry.viewPoint(x: 100, y: 50, viewport: viewport)

        #expect(point == CGPoint(x: 80, y: 40))
    }

    @Test("a point above or left of the visible part is outside the view")
    func pointBeforeTheVisiblePartIsNil() {
        let geometry = BrowserViewGeometry(size: CGSize(width: 800, height: 600), isFlipped: true, pageZoom: 1)
        let viewport = BrowserVisualViewport(offsetLeft: 50, offsetTop: 50, scale: 1)

        #expect(geometry.viewPoint(x: 10, y: 10, viewport: viewport) == nil)
    }

    @Test("a point at or past the view's far edge is outside the view")
    func pointPastTheFarEdgeIsNil() {
        let geometry = BrowserViewGeometry(size: CGSize(width: 100, height: 100), isFlipped: true, pageZoom: 1)

        #expect(geometry.viewPoint(x: 100, y: 50, viewport: Self.identityViewport) == nil)
        #expect(geometry.viewPoint(x: 50, y: 100, viewport: Self.identityViewport) == nil)
    }

    @Test("a box's centre is the point a click lands at")
    func centerOfABox() {
        let geometry = BrowserViewGeometry(size: CGSize(width: 800, height: 600), isFlipped: true, pageZoom: 1)
        let box = BrowserElementBox(x: 100, y: 100, width: 40, height: 20, viewport: Self.identityViewport)

        #expect(geometry.center(of: box) == CGPoint(x: 120, y: 110))
    }

    @Test("a box with no rendered size still answers a centre point")
    func zeroSizeBoxStillAnswers() {
        let geometry = BrowserViewGeometry(size: CGSize(width: 800, height: 600), isFlipped: true, pageZoom: 1)
        let box = BrowserElementBox(x: 100, y: 100, width: 0, height: 0, viewport: Self.identityViewport)

        #expect(geometry.center(of: box) == CGPoint(x: 100, y: 100))
    }
}
