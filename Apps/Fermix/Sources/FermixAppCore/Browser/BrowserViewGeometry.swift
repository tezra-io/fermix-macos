import CoreGraphics

/// The page's visual viewport, as `window.visualViewport` reports it: where
/// the part on screen sits in the layout viewport, and how far it is zoomed.
public struct BrowserVisualViewport: Decodable, Equatable, Sendable {
    public var offsetLeft: Double
    public var offsetTop: Double
    public var scale: Double

    public init(offsetLeft: Double = 0, offsetTop: Double = 0, scale: Double = 1) {
        self.offsetLeft = offsetLeft
        self.offsetTop = offsetTop
        self.scale = scale
    }
}

/// An element's box in the top document's layout viewport, in CSS pixels,
/// read once the element was scrolled into view.
public struct BrowserElementBox: Decodable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var viewport: BrowserVisualViewport

    public init(x: Double, y: Double, width: Double, height: Double, viewport: BrowserVisualViewport = BrowserVisualViewport()) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.viewport = viewport
    }
}

/// Where a point of the page lands in its web view.
///
/// CSS pixels become points through the page zoom and the visual viewport's
/// own zoom, measured from the visible part's corner; a view that is not
/// flipped counts y from the bottom. Input is delivered at the point this
/// answers, so a point outside the view is refused rather than clamped.
public struct BrowserViewGeometry: Equatable, Sendable {
    public var size: CGSize
    public var isFlipped: Bool
    public var pageZoom: Double

    public init(size: CGSize, isFlipped: Bool, pageZoom: Double) {
        self.size = size
        self.isFlipped = isFlipped
        self.pageZoom = pageZoom
    }

    /// The view point under a layout-viewport point, or nil outside the view.
    public func viewPoint(x: Double, y: Double, viewport: BrowserVisualViewport) -> CGPoint? {
        let scale = pageZoom * viewport.scale
        let across = (x - viewport.offsetLeft) * scale
        let down = (y - viewport.offsetTop) * scale
        guard across >= 0, down >= 0, across < size.width, down < size.height else { return nil }

        return CGPoint(x: across, y: isFlipped ? down : size.height - down)
    }

    /// The view point at the centre of a box, where a click lands.
    public func center(of box: BrowserElementBox) -> CGPoint? {
        viewPoint(x: box.x + box.width / 2, y: box.y + box.height / 2, viewport: box.viewport)
    }
}
