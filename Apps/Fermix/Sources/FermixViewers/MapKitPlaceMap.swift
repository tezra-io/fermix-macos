import AppKit
import FermixAppCore
import MapKit

/// The chat's maps (M72 §7.2, §14.1): a picture of an area from the Mac's own
/// maps, nothing bundled, and no live map view in the transcript; and a place
/// Apple Maps found, at Apple's own card for it, drawn for the chat's popover
/// or opened in Maps.
///
/// The only module that imports MapKit. `FermixAppCore` declares
/// `PlaceMaps` and imports it nowhere, because both executables link that
/// library and `FermixAgent` draws no map; the media reader `main.swift`
/// hands in is what draws one, draws a place's card and opens a place.
extension SystemMediaReader {
    public func map(of area: PlaceMapArea, size: CGSize, appearance: PlaceMapAppearance) async throws -> CGImage {
        let snapshot = PendingSnapshot(options: Self.options(area, size: size, appearance: appearance))
        let drawn = try await withTaskCancellationHandler {
            try await snapshot.take()
        } onCancel: {
            snapshot.cancel()
        }

        var rect = CGRect(origin: .zero, size: size)
        guard let image = drawn.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw MKError(.unknown)
        }

        return image
    }

    /// Apple's own card for the place, as MapKit draws it (`PlaceCard`).
    @MainActor
    public func placeCard(
        _ identifier: String,
        size: CGSize,
        finished: @escaping @MainActor () -> Void
    ) async throws -> NSViewController {
        PlaceCard(place: try await Self.place(identifier), size: size, finished: finished)
    }

    /// Apple's own place for the identifier, then Maps on it. A place Maps
    /// cannot give, and a Maps that does not open, are each a failure.
    @MainActor
    public func openPlace(_ identifier: String, failed: @escaping @MainActor () -> Void) {
        Task {
            guard let item = try? await Self.place(identifier) else {
                failed()
                return
            }

            item.openInMaps(launchOptions: nil) { opened in
                guard !opened else { return }

                Task { @MainActor in failed() }
            }
        }
    }

    /// The place Apple Maps knows by the identifier, as Maps has it now, for
    /// its card and for Maps alike. An identifier that does not parse and a
    /// place Maps no longer has each throw, and neither is looked up by any
    /// other way.
    @MainActor
    private static func place(_ identifier: String) async throws -> MKMapItem {
        guard let identifier = MKMapItem.Identifier(rawValue: identifier) else {
            throw MKError(.placemarkNotFound)
        }

        return try await withCheckedThrowingContinuation { continuation in
            MKMapItemRequest(mapItemIdentifier: identifier).getMapItem { item, error in
                continuation.resume(with: item.map(Result.success) ?? .failure(error ?? MKError(.placemarkNotFound)))
            }
        }
    }

    /// Exactly the area, which keeps the picture's proportion, so a place
    /// falls where the area's own projection says, in the standard map at its
    /// quietest, flat and muted, with no points of interest of its own.
    private static func options(_ area: PlaceMapArea, size: CGSize, appearance: PlaceMapAppearance) -> MKMapSnapshotter.Options {
        let world = MKMapSize.world
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll

        let options = MKMapSnapshotter.Options()
        options.mapRect = MKMapRect(
            x: area.x * world.width,
            y: area.y * world.height,
            width: area.width * world.width,
            height: area.height * world.height
        )
        options.size = size
        options.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        options.preferredConfiguration = configuration
        return options
    }
}

/// Apple's own card for a place Apple Maps found, without the small map of its
/// own it can show: the reply's map beside the popover already shows where
/// the place is, with its pin. MapKit's card keeps its delegate weakly and
/// takes no subclass, so it is held here, by a controller of its own that is
/// its delegate for as long as it shows, and its close button reaches
/// `finished`.
private final class PlaceCard: NSViewController, MKMapItemDetailViewControllerDelegate {
    private let card: MKMapItemDetailViewController
    private let size: CGSize
    private let finished: @MainActor () -> Void

    init(place: MKMapItem, size: CGSize, finished: @escaping @MainActor () -> Void) {
        card = MKMapItemDetailViewController(mapItem: place, displaysMap: false)
        self.size = size
        self.finished = finished
        super.init(nibName: nil, bundle: nil)
        card.delegate = self
        addChild(card)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("a place card is built in code")
    }

    /// The card fills this controller's view, which is the popover's size
    /// and no other. The card lays itself out by constraints and asks for a
    /// height of its own, taller than the popover's, so it is pinned to this
    /// view's edges with that ask let go of, and scrolls inside the
    /// popover's height rather than growing past it and losing its top.
    override func loadView() {
        let shown = card.view
        view = NSView(frame: NSRect(origin: .zero, size: size))
        shown.translatesAutoresizingMaskIntoConstraints = false
        shown.setContentHuggingPriority(.defaultLow, for: .vertical)
        shown.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.addSubview(shown)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: size.width),
            view.heightAnchor.constraint(equalToConstant: size.height),
            shown.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            shown.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            shown.topAnchor.constraint(equalTo: view.topAnchor),
            shown.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func mapItemDetailViewControllerDidFinish(_ detailViewController: MKMapItemDetailViewController) {
        finished()
    }
}

/// One snapshot, which its cancellation reaches from whichever thread the
/// asking task is cancelled on: the snapshotter takes a cancel from any
/// thread, which its type does not declare. A cancelled snapshotter calls no
/// handler at all, so the cancel answers the wait itself, and whichever of
/// the two comes first is the only answer.
private final class PendingSnapshot: @unchecked Sendable {
    private let snapshotter: MKMapSnapshotter
    private let lock = NSLock()
    private var waiting: CheckedContinuation<MKMapSnapshotter.Snapshot, Error>?
    private var cancelled = false

    init(options: MKMapSnapshotter.Options) {
        snapshotter = MKMapSnapshotter(options: options)
    }

    func take() async throws -> MKMapSnapshotter.Snapshot {
        try await withCheckedThrowingContinuation { continuation in
            let early = lock.withLock {
                guard !cancelled else { return true }

                waiting = continuation
                return false
            }
            guard !early else {
                continuation.resume(throwing: CancellationError())
                return
            }

            snapshotter.start(with: .global(qos: .utility)) { snapshot, error in
                self.answer(snapshot.map { .success($0) } ?? .failure(error ?? MKError(.unknown)))
            }
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
        snapshotter.cancel()
        answer(.failure(CancellationError()))
    }

    private func answer(_ result: Result<MKMapSnapshotter.Snapshot, Error>) {
        let continuation = lock.withLock {
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume(with: result)
    }
}
