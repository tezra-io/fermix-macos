import AppKit
import FermixAppCore
import MapKit

/// A reply's map, live (M72 §14.1, `PlaceLiveMap`): exactly its area, drawn
/// as its picture is (`SystemMediaReader.configuration`), with each place's
/// pin the core's own face for it, and nothing the person can pan or zoom.
/// The place shown is Apple's place for its identifier, selected, so Apple's
/// compact callout hangs from its pin: its name, its kind and street,
/// whether it is open now, and Open in Apple Maps.
///
/// What the person does is the core's to decide, so every click comes back
/// as a pin's number, or as nil for the empty map or Escape. MapKit selects
/// a clicked pin before its view hears the click, and says nothing when the
/// pin clicked is the place already shown, so a pin's own view tells the
/// click (`PlacePinView`), and a deselection is the empty map's only once
/// MapKit is done and nothing else is selected.
///
/// The map stands in for its picture only once it is drawn as the picture
/// is, its labels and all: MapKit says when the map is drawn and not when
/// its labels have faded in after it, which they do within about half a
/// second of it where the picture's tiles are already loaded, so the map
/// waits that long more (`labelsSettle`). Only then is the place selected,
/// so a callout too near the map's top or bottom moves the map in view,
/// smoothly, from exactly the picture's framing, as MapKit fits it; putting
/// the place away moves the map back to exactly its area, smoothly, before
/// the picture of it takes its place.
///
/// The map stands in a plain view of its own, and that view is what the
/// chat lays out. Apple's callout asks for layout about twice a second, and
/// in the transcript's scroll view each ask lays the hosted view out again,
/// unchanged; MapKit answers that by drawing its pins and the callout a pixel
/// off for a frame, every frame while it slides the map to fit a callout,
/// so they shake. The view between them keeps the chat's layout off the map.
@MainActor
final class LivePlaceMap: NSObject, PlaceLiveMap, MKMapViewDelegate {
    private let stand: NSView
    private let map: PlaceMapView
    private let area: MKMapRect
    private let faces: [Int: NSView]
    private let clicked: @MainActor (Int?) -> Void
    /// Each pin's annotation, by its number: a plain one until its place has
    /// been shown, Apple's place from then on.
    private var marks: [Int: any MKAnnotation] = [:]
    /// Whether the map has been drawn whole once, with its labels settled,
    /// and who waits for it.
    private var drawn = false
    private var settling = false
    private var waitingToBeDrawn: [CheckedContinuation<Void, Never>] = []
    /// Who waits for the map to be back at exactly its area.
    private var waitingForArea: [CheckedContinuation<Void, Never>] = []
    /// While the place is being put away, its deselection is the map's own
    /// and says nothing to the core.
    private var puttingAway = false

    var view: NSView { stand }

    init(
        area: MKMapRect,
        size: CGSize,
        appearance: NSAppearance?,
        pins: [PlaceMapPin],
        clicked: @escaping @MainActor (Int?) -> Void
    ) {
        stand = NSView(frame: NSRect(origin: .zero, size: size))
        map = PlaceMapView(frame: stand.bounds)
        map.autoresizingMask = [.width, .height]
        stand.addSubview(map)
        self.area = area
        faces = Dictionary(uniqueKeysWithValues: pins.map { ($0.number, $0.face) })
        self.clicked = clicked
        super.init()

        map.appearance = appearance
        map.preferredConfiguration = SystemMediaReader.configuration()
        map.showsZoomControls = false
        map.showsCompass = false
        map.showsScale = false
        map.showsPitchControl = false
        map.isZoomEnabled = false
        map.isScrollEnabled = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.escaped = { clicked(nil) }
        map.delegate = self
        map.setVisibleMapRect(area, animated: false)
        for pin in pins {
            let mark = PlacePinMark(coordinate: Self.coordinate(pin.location))
            marks[pin.number] = mark
            map.addAnnotation(mark)
        }
    }

    func show(_ number: Int, identifier: String) async throws {
        puttingAway = false
        let mark = try await apple(number, identifier: identifier)
        await wait(for: .drawn)
        try Task.checkCancellation()

        map.selectAnnotation(mark, animated: true)
    }

    func putAway() async {
        puttingAway = true
        for selected in map.selectedAnnotations {
            map.deselectAnnotation(selected, animated: true)
        }
        guard !atArea else { return }

        map.setVisibleMapRect(area, animated: true)
        await wait(for: .area)
    }

    /// The pin's annotation as Apple's place for the identifier, looked up
    /// the first time its place is shown and kept for the map's life.
    private func apple(_ number: Int, identifier: String) async throws -> MKMapItemAnnotation {
        if let mark = marks[number] as? MKMapItemAnnotation { return mark }

        let place = try await SystemMediaReader.place(identifier)
        try Task.checkCancellation()
        guard let mark = MKMapItemAnnotation(mapItem: place), let plain = marks[number] else {
            throw MKError(.placemarkNotFound)
        }

        map.removeAnnotation(plain)
        marks[number] = mark
        map.addAnnotation(mark)
        return mark
    }

    // MARK: - MapKit

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        guard let number = marks.first(where: { $0.value === annotation })?.key, let face = faces[number] else {
            return nil
        }

        return PlacePinView(annotation: annotation, face: face) { [clicked] in clicked(number) }
    }

    func mapView(_ mapView: MKMapView, selectionAccessoryFor annotation: any MKAnnotation) -> MKSelectionAccessory? {
        annotation is MKMapItemAnnotation ? .mapItemDetail(.callout(.compact)) : nil
    }

    /// A click on the empty map deselects the place shown; a click on
    /// another pin deselects it too, and selects that pin, which its view
    /// tells. Which it was is known once MapKit is done.
    func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
        Task { @MainActor in
            guard !puttingAway, map.selectedAnnotations.isEmpty else { return }

            clicked(nil)
        }
    }

    /// The first time the map is drawn whole, and its labels have had time
    /// to fade in after it.
    func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
        guard fullyRendered, !drawn, !settling else { return }

        settling = true
        Task { @MainActor in
            try? await Task.sleep(for: Self.labelsSettle)
            drawn = true
            resume(.drawn)
        }
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        guard atArea else { return }

        resume(.area)
    }

    // MARK: - Waiting

    private enum Wait {
        case drawn
        case area
    }

    /// Until the map is drawn whole once, or back at exactly its area, or
    /// until the task waiting is cancelled, which then finds out for itself.
    private func wait(for what: Wait) async {
        switch what {
        case .drawn where drawn, .area where atArea: return
        case .drawn, .area: break
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                switch what {
                case .drawn: waitingToBeDrawn.append(continuation)
                case .area: waitingForArea.append(continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in self.resume(what) }
        }
    }

    private func resume(_ what: Wait) {
        let waiting: [CheckedContinuation<Void, Never>]
        switch what {
        case .drawn:
            waiting = waitingToBeDrawn
            waitingToBeDrawn = []
        case .area:
            waiting = waitingForArea
            waitingForArea = []
        }
        waiting.forEach { $0.resume() }
    }

    /// Whether the map shows exactly its area, to well under a point.
    private var atArea: Bool {
        let shown = map.visibleMapRect
        let tolerance = area.size.width / 10_000
        return abs(shown.origin.x - area.origin.x) < tolerance && abs(shown.origin.y - area.origin.y) < tolerance
            && abs(shown.size.width - area.size.width) < tolerance
    }

    /// How long a map drawn whole takes to fade its labels in, which MapKit
    /// says nothing of: the longest seen over the fixture's area with its
    /// tiles already loaded for the picture, and room to spare.
    private static let labelsSettle: Duration = .milliseconds(500)

    private static func coordinate(_ location: CompanionPlaceLocation) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
    }
}

/// The live map's view, which leaves scrolling to the transcript it stands
/// in, so a wheel over it still scrolls the chat, and hears Escape.
private final class PlaceMapView: MKMapView {
    var escaped: @MainActor () -> Void = {}

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        escaped()
    }
}

/// A pin whose place has not been shown yet: where it is, and nothing more.
private final class PlacePinMark: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}

/// A pin on the live map: the core's face for it, centred on the place, as on
/// the picture. Apple's callout hangs from the selected pin's view, outside
/// its bounds, so the view never clips. A click inside the pin itself is
/// told, whether or not its place is shown; a click on the callout is the
/// callout's.
private final class PlacePinView: MKAnnotationView {
    private let clicked: @MainActor () -> Void

    init(annotation: any MKAnnotation, face: NSView, clicked: @escaping @MainActor () -> Void) {
        self.clicked = clicked
        super.init(annotation: annotation, reuseIdentifier: nil)
        frame = NSRect(origin: .zero, size: face.fittingSize)
        clipsToBounds = false
        displayPriority = .required
        face.frame = bounds
        face.autoresizingMask = [.width, .height]
        addSubview(face)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("a pin is built in code")
    }

    /// The pin answers for its own disc, so the face drawn in it never takes
    /// the click; everything outside it, the callout among it, answers for
    /// itself.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            clicked()
        }
        super.mouseDown(with: event)
    }
}
