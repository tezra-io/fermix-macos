import Foundation

/// Packet-4 framing: one big-endian 32-bit byte length followed by exactly that
/// many bytes of UTF-8 JSON.
///
/// A frame arrives whole or not at all, so a short read is a hard error rather
/// than a partial result to be stitched together. The ceiling is enforced on
/// both ends: an oversized request is refused before it is written, and an
/// oversized response is refused from its header alone, before a buffer for it
/// is allocated.
enum ManagementFraming {
    static let headerLength = 4

    static func header(payloadLength: Int, limit: Int) throws -> Data {
        guard payloadLength > 0 else { throw ManagementTransportFailure.emptyFrame }
        guard payloadLength <= limit else {
            throw ManagementTransportFailure.frameTooLarge(byteCount: payloadLength, limit: limit)
        }

        var header = Data(capacity: headerLength)
        withUnsafeBytes(of: UInt32(payloadLength).bigEndian) { header.append(contentsOf: $0) }
        return header
    }

    static func payloadLength(fromHeader header: Data, limit: Int) throws -> Int {
        guard header.count == headerLength else {
            throw ManagementTransportFailure.shortFrame(
                expected: headerLength,
                received: header.count
            )
        }

        let length = Int(header.withUnsafeBytes { raw in
            UInt32(bigEndian: raw.loadUnaligned(as: UInt32.self))
        })
        guard length > 0 else { throw ManagementTransportFailure.emptyFrame }
        guard length <= limit else {
            throw ManagementTransportFailure.frameTooLarge(byteCount: length, limit: limit)
        }
        return length
    }
}
