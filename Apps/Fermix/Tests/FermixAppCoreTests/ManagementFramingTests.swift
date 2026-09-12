import Foundation
import Testing

@testable import FermixAppCore

/// Packet-4 framing: one big-endian 32-bit length, then exactly that many bytes
/// of UTF-8 JSON. A frame arrives whole or not at all, so anything short is a
/// hard error rather than a partial read to be retried.
@Suite("Management framing")
struct ManagementFramingTests {
    private let limit = 4_194_304

    @Test("the header is four big-endian bytes")
    func headerIsBigEndian() throws {
        let header = try ManagementFraming.header(payloadLength: 1_048_576, limit: limit)

        #expect(Array(header) == [0x00, 0x10, 0x00, 0x00])
    }

    @Test("a header round-trips through the length reader")
    func headerRoundTrips() throws {
        for length in [1, 2, 255, 256, 65_535, 1_048_576, 4_194_304] {
            let header = try ManagementFraming.header(payloadLength: length, limit: limit)
            #expect(try ManagementFraming.payloadLength(fromHeader: header, limit: limit) == length)
        }
    }

    @Test("an outbound payload over the ceiling is refused before it is written")
    func outboundOverCeilingIsRefused() {
        #expect(throws: ManagementTransportFailure.frameTooLarge(byteCount: limit + 1, limit: limit)) {
            _ = try ManagementFraming.header(payloadLength: limit + 1, limit: limit)
        }
    }

    @Test("an inbound length over the ceiling is refused from the header alone")
    func inboundOverCeilingIsRefused() {
        var header = Data(count: 4)
        header[0] = 0x00
        header[1] = 0x40
        header[2] = 0x00
        header[3] = 0x01

        #expect(
            throws: ManagementTransportFailure.frameTooLarge(byteCount: 4_194_305, limit: limit)
        ) {
            _ = try ManagementFraming.payloadLength(fromHeader: header, limit: limit)
        }
    }

    @Test("a short header is a hard error")
    func shortHeaderIsRefused() {
        #expect(throws: ManagementTransportFailure.shortFrame(expected: 4, received: 3)) {
            _ = try ManagementFraming.payloadLength(fromHeader: Data([0, 0, 1]), limit: limit)
        }
    }

    @Test("a zero-length frame is refused")
    func zeroLengthFrameIsRefused() {
        #expect(throws: ManagementTransportFailure.emptyFrame) {
            _ = try ManagementFraming.payloadLength(fromHeader: Data([0, 0, 0, 0]), limit: limit)
        }
    }

    @Test("a negative or zero outbound payload is refused")
    func emptyOutboundPayloadIsRefused() {
        #expect(throws: ManagementTransportFailure.emptyFrame) {
            _ = try ManagementFraming.header(payloadLength: 0, limit: limit)
        }
    }
}
