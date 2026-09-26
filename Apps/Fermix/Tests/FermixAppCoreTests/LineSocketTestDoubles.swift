import Foundation

@testable import FermixAppCore

/// A line socket that records every line sent and lets a test deliver decoded
/// messages and failures by hand. No socket, no queue, no daemon.
///
/// Any wire's adapter runs over it unchanged, so a case drives the real adapter
/// and reads back exactly the lines that adapter produced.
///
/// Not main-actor isolated, because the seam it stands in for is not: the real
/// client calls back on its own queue and the owner's delivery is what hops.
/// Every case drives it from one thread, one call at a time.
final class FakeLineSocketTransport<Message: Sendable, DecodeFailure: Error & Equatable & Sendable>:
    LineSocketTransport, @unchecked Sendable
{
    var onMessage: ((Message) -> Void)?
    var onFailure: ((LineSocketFailure<DecodeFailure>) -> Void)?

    private(set) var connectedPaths: [String] = []
    /// Lines that must arrive, in order, without their terminator.
    private(set) var sent: [Data] = []
    /// Droppable lines, in order, without their terminator.
    private(set) var sentDroppable: [Data] = []
    private(set) var closeCount = 0

    /// The result the next `connect` reports. Connecting is asynchronous in
    /// production, so the completion can be held and fired by the test.
    var connectResult: Result<Void, LineSocketConnectFailure> = .success(())
    var deferConnectCompletion = false
    private var pendingCompletion: ((Result<Void, LineSocketConnectFailure>) -> Void)?

    func connect(path: String, completion: @escaping (Result<Void, LineSocketConnectFailure>) -> Void) {
        connectedPaths.append(path)
        guard !deferConnectCompletion else {
            pendingCompletion = completion
            return
        }
        completion(connectResult)
    }

    func completeConnect(_ result: Result<Void, LineSocketConnectFailure>) {
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(result)
    }

    func send(_ line: Data) {
        sent.append(line)
    }

    func sendDroppable(_ line: Data) {
        sentDroppable.append(line)
    }

    func close() {
        closeCount += 1
    }

    func deliver(_ message: Message) {
        onMessage?(message)
    }

    func fail(_ failure: LineSocketFailure<DecodeFailure>) {
        onFailure?(failure)
    }

    /// The lines that must arrive, each as the JSON object it carries.
    func sentObjects() throws -> [NSDictionary] {
        try sent.map(wireObject)
    }

    /// The droppable lines, each as the JSON object it carries.
    func sentDroppableObjects() throws -> [NSDictionary] {
        try sentDroppable.map(wireObject)
    }
}

enum WireLineDefect: Error, Equatable {
    case notAnObject(String)
}

/// A JSON line as the object it carries. `JSONEncoder` promises no key order,
/// so two encodings of one value are the same object but not always the same
/// bytes: lines are compared this way, never byte for byte.
func wireObject(_ line: Data) throws -> NSDictionary {
    guard let object = try JSONSerialization.jsonObject(with: line) as? NSDictionary else {
        throw WireLineDefect.notAnObject(String(decoding: line, as: UTF8.self))
    }

    return object
}
