import AppKit
import FermixAppCore
import MapKit

/// The chat's maps (M72 §7.2): a picture of an area from the Mac's own maps,
/// nothing bundled, and no live map view in the transcript.
///
/// The only module that imports MapKit. `FermixAppCore` declares
/// `PlaceMapDrawing` and imports it nowhere, because both executables link
/// that library and `FermixAgent` draws no map; the media reader `main.swift`
/// hands in is what draws one.
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
