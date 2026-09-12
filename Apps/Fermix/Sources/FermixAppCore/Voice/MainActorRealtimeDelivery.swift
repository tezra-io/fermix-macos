import Foundation

/// Puts a transport's callbacks on the main actor.
///
/// `RealtimeSocketClient` confines every byte of its state to one serial queue
/// and calls back on it, which is what keeps the socket off the main thread.
/// `VoiceSession` is main-actor state. This is the one place the two meet, so
/// no consumer has to remember which thread it is on and no other type hops.
public final class MainActorRealtimeDelivery: RealtimeTransport, @unchecked Sendable {
    public var onEvent: ((RealtimeServerEvent) -> Void)?
    public var onFailure: ((RealtimeTransportFailure) -> Void)?

    private let wrapped: any RealtimeTransport

    public init(wrapping transport: any RealtimeTransport) {
        self.wrapped = transport

        transport.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.onEvent?(event)
            }
        }
        transport.onFailure = { [weak self] failure in
            DispatchQueue.main.async {
                self?.onFailure?(failure)
            }
        }
    }

    public func connect(
        path: String,
        completion: @escaping (Result<Void, RealtimeConnectFailure>) -> Void
    ) {
        wrapped.connect(path: path) { result in
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    public func send(_ event: RealtimeClientEvent) {
        wrapped.send(event)
    }

    public func sendAudioChunk(_ data: Data) {
        wrapped.sendAudioChunk(data)
    }

    public func close() {
        wrapped.close()
    }
}
