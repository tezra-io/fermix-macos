import Foundation

/// The reader's framing: bytes in, typed events out, both bounds enforced.
///
/// Two limits, each with its own job. The whole-buffer limit refuses a burst
/// larger than this client will ever hold before it is scanned. The frame limit
/// refuses one over-length line, including an unterminated run that has already
/// passed the ceiling — a peer that never sends a newline is stopped there
/// rather than allowed to grow the buffer to the whole-buffer limit first.
struct RealtimeInboundBuffer {
    private var pending = Data()

    /// Bytes held for a line whose newline has not arrived.
    var pendingByteCount: Int { pending.count }

    /// Appends a read and delivers every complete frame it completes.
    mutating func append(_ bytes: Data, deliver: (RealtimeServerEvent) -> Void) throws {
        let total = pending.count + bytes.count
        guard total <= RealtimeProtocol.maximumInboundBufferBytes else {
            pending.removeAll()
            throw RealtimeDecodeFailure.inboundBufferExceeded(bytes: total)
        }

        pending.append(bytes)
        try drain(deliver: deliver)
    }

    mutating func reset() {
        pending.removeAll()
    }

    private mutating func drain(deliver: (RealtimeServerEvent) -> Void) throws {
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)

            guard line.count <= RealtimeProtocol.maximumFrameBytes else {
                pending.removeAll()
                throw RealtimeDecodeFailure.frameTooLarge(bytes: line.count)
            }
            guard !line.isEmpty else { continue }

            deliver(try RealtimeServerEvent.decode(line))
        }

        // No newline left: what remains is one unfinished frame, and it is
        // already too long to ever become a legal one.
        guard pending.count <= RealtimeProtocol.maximumFrameBytes else {
            let count = pending.count
            pending.removeAll()
            throw RealtimeDecodeFailure.frameTooLarge(bytes: count)
        }
    }
}
