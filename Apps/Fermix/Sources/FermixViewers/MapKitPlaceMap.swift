import AppKit
import FermixAppCore
import MapKit

/// The chat's maps (M72 §7.2, §14.1): a picture of an area from the Mac's own
/// maps, nothing bundled; the same area live, only while a place is shown on
/// it (`LivePlaceMap`); and a place Apple Maps found, opened in Maps at
/// Apple's own card for it.
///
/// The only module that imports MapKit. `FermixAppCore` declares
/// `PlaceMaps` and imports it nowhere, because both executables link that
/// library and `FermixAgent` draws no map; the media reader `main.swift`
/// hands in is what draws one, live or not, and opens a place.
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

    @MainActor
    public func liveMap(
        of area: PlaceMapArea,
        size: CGSize,
        appearance: PlaceMapAppearance,
        pins: [PlaceMapPin],
        clicked: @escaping @MainActor (Int?) -> Void
    ) -> any PlaceLiveMap {
        LivePlaceMap(area: Self.mapRect(area), size: size, appearance: Self.appearance(appearance), pins: pins, clicked: clicked)
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
    /// the live map and for Maps alike. An identifier that does not parse and
    /// a place Maps no longer has each throw, and neither is looked up by any
    /// other way.
    @MainActor
    static func place(_ identifier: String) async throws -> MKMapItem {
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
    /// falls where the area's own projection says, in the map the chat
    /// draws (`configuration`).
    private static func options(_ area: PlaceMapArea, size: CGSize, appearance: PlaceMapAppearance) -> MKMapSnapshotter.Options {
        let options = MKMapSnapshotter.Options()
        options.mapRect = mapRect(area)
        options.size = size
        options.appearance = Self.appearance(appearance)
        options.preferredConfiguration = configuration()
        return options
    }

    /// The area on Apple's map: the unit square scaled to the world's map
    /// points, the one answer to what a reply's map shows, picture or live.
    static func mapRect(_ area: PlaceMapArea) -> MKMapRect {
        let world = MKMapSize.world
        return MKMapRect(
            x: area.x * world.width,
            y: area.y * world.height,
            width: area.width * world.width,
            height: area.height * world.height
        )
    }

    /// The map the chat draws, picture or live: the standard map at its
    /// quietest, flat and muted, with no points of interest of its own.
    static func configuration() -> MKStandardMapConfiguration {
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        return configuration
    }

    static func appearance(_ appearance: PlaceMapAppearance) -> NSAppearance? {
        NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
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
