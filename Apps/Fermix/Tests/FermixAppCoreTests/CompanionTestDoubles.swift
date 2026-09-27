import Foundation

@testable import FermixAppCore

/// The companion daemon's side of the socket, driven by hand: a session built
/// over `CompanionSocketClient(lines:)` on one of these crosses the real adapter
/// in both directions, and a case reads back the lines it put on the wire.
typealias FakeCompanionSocket = FakeLineSocketTransport<CompanionServerEvent, CompanionDecodeFailure>

/// The object a client event goes on the wire as, for comparing against what a
/// fake line socket recorded. Labelled, because the realtime wire's events share
/// case names with these and an implicit member would not know which it meant.
func wireObject(companion event: CompanionClientEvent) throws -> NSDictionary {
    try wireObject(event.line())
}
