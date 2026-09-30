import Foundation

/// Puts a line socket's callbacks on the main actor, for any wire.
///
/// `LineSocketClient` confines every byte of its state to one serial queue and
/// calls back on it, which is what keeps the socket off the main thread. The
/// sessions above a wire are main-actor state. This is the one place the two
/// meet, so no adapter or session has to remember which thread it is on and no
/// other type hops.
///
/// Everything outbound passes straight through: the socket's own queue is where
/// a line is framed and written, whichever thread asked.
public final class MainActorLineDelivery<Message: Sendable, DecodeFailure: Error & Equatable & Sendable>:
    LineSocketTransport, @unchecked Sendable
{
    public var onMessage: ((Message) -> Void)?
    public var onFailure: ((LineSocketFailure<DecodeFailure>) -> Void)?

    private let wrapped: any LineSocketTransport<Message, DecodeFailure>

    public init(wrapping lines: any LineSocketTransport<Message, DecodeFailure>) {
        self.wrapped = lines

        lines.onMessage = { [weak self] message in
            DispatchQueue.main.async {
                self?.onMessage?(message)
            }
        }
        lines.onFailure = { [weak self] failure in
            DispatchQueue.main.async {
                self?.onFailure?(failure)
            }
        }
    }

    public func connect(
        path: String,
        completion: @escaping (Result<Void, LineSocketConnectFailure>) -> Void
    ) {
        wrapped.connect(path: path) { result in
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    public func send(_ line: Data) {
        wrapped.send(line)
    }

    public func sendDroppable(_ line: Data) {
        wrapped.sendDroppable(line)
    }

    public func sendDroppable(producing line: @escaping @Sendable () -> Data) {
        wrapped.sendDroppable(producing: line)
    }

    public func close() {
        wrapped.close()
    }
}
