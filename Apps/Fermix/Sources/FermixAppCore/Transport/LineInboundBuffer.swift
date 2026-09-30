import Foundation

/// The reader's framing: bytes in, decoded messages out, both bounds enforced.
///
/// Two limits, each with its own job. The whole-buffer limit refuses a burst
/// larger than this client will ever hold before it is scanned. The line limit
/// refuses one over-length line, including an unterminated run that has already
/// passed the ceiling — a peer that never sends a newline is stopped there
/// rather than allowed to grow the buffer to the whole-buffer limit first.
struct LineInboundBuffer<Message, DecodeFailure: Error & Equatable & Sendable> {
    let limits: LineInboundLimits
    let decode: @Sendable (Data) throws(DecodeFailure) -> Message

    private var pending = Data()

    init(limits: LineInboundLimits, decode: @escaping @Sendable (Data) throws(DecodeFailure) -> Message) {
        self.limits = limits
        self.decode = decode
    }

    /// Bytes held for a line whose newline has not arrived.
    var pendingByteCount: Int { pending.count }

    /// Appends a read and delivers every complete line it completes, decoded.
    mutating func append(
        _ bytes: Data,
        deliver: (Message) -> Void
    ) throws(LineSocketFailure<DecodeFailure>) {
        let total = pending.count + bytes.count
        guard total <= limits.maximumBufferedBytes else {
            pending.removeAll()
            throw .framingViolation(.bufferExceeded(bytes: total))
        }

        pending.append(bytes)
        try drain(deliver: deliver)
    }

    mutating func reset() {
        pending.removeAll()
    }

    private mutating func drain(deliver: (Message) -> Void) throws(LineSocketFailure<DecodeFailure>) {
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)

            guard line.count <= limits.maximumLineBytes else {
                pending.removeAll()
                throw .framingViolation(.lineTooLong(bytes: line.count))
            }
            guard !line.isEmpty else { continue }

            deliver(try decodeLine(line))
        }

        // No newline left: what remains is one unfinished line, and it is
        // already too long to ever become a legal one.
        guard pending.count <= limits.maximumLineBytes else {
            let count = pending.count
            pending.removeAll()
            throw .framingViolation(.lineTooLong(bytes: count))
        }
    }

    private func decodeLine(_ line: Data) throws(LineSocketFailure<DecodeFailure>) -> Message {
        do throws(DecodeFailure) {
            return try decode(line)
        } catch {
            throw .undecodable(error)
        }
    }
}
