import FermixAppCore
import Foundation
import WebKit

/// A page read the way Chrome's accessibility tree lists it (plan §4.8), for
/// the engine's own renderer.
///
/// The request's mode, character budget and depth reach the script only as
/// hints that bound its walk; the engine renders and truncates. The evaluate
/// is timed from the call to the decoded answer, which is the cost the
/// engine's settle budget pays.
@MainActor
final class WebKitPageSnapshot {
    private let script: WebKitPageScript

    init(script: WebKitPageScript) {
        self.script = script
    }

    func take(_ request: BrowserSnapshotRequest) async throws -> BrowserPageSnapshot {
        let started = ContinuousClock.now
        let json = try await script.text("snapshot", [options(request)])
        let elapsed = started.duration(to: .now)

        return try BrowserPageSnapshot.decode(Data(json.utf8), evaluateMilliseconds: elapsed.milliseconds)
    }

    private func options(_ request: BrowserSnapshotRequest) -> [String: Any] {
        [
            "mode": request.mode.rawValue,
            "maxChars": request.maxChars,
            "depth": request.depth,
            "closedShadowRoots": WebKitPageScript.readsClosedShadowRoots
        ]
    }
}

extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
