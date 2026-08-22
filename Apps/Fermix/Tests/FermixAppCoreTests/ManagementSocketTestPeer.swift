import Darwin
import Foundation

/// A packet-4 peer for `UnixSocketManagementTransport`: binds an AF_UNIX
/// socket, accepts one connection, reads one framed request, then answers
/// according to the scripted behavior. It speaks the wire the daemon speaks, so
/// the transport is exercised against real bytes rather than a stub.
final class ManagementSocketTestPeer {
    enum Behavior {
        /// Frame and return this payload.
        case answer(Data)
        /// Write these bytes verbatim (used for malformed and oversized frames).
        case rawBytes(Data)
        /// Accept, then close without answering.
        case closeWithoutAnswering
        /// Accept and hold the connection open, answering nothing.
        case silence
    }

    let path: String

    private let listenFD: Int32
    private let behavior: Behavior
    private let queue = DispatchQueue(label: "test.management.peer")
    private let lock = NSLock()
    private var receivedPayload: Data?
    private var acceptedFD: Int32 = -1

    init(behavior: Behavior) throws {
        self.behavior = behavior
        self.path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fermix-mgmt-\(UUID().uuidString.prefix(8)).sock")

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        self.listenFD = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { destination in
            path.utf8CString.withUnsafeBufferPointer { source in
                destination.copyBytes(from: UnsafeRawBufferPointer(source))
            }
        }

        unlink(path)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                Darwin.bind(fd, address, size)
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        queue.async { [weak self] in self?.serve() }
    }

    /// The request payload the peer read, once it has arrived.
    func requestPayload(timeout: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let payload = receivedPayload
            lock.unlock()
            if payload != nil { return payload }
            usleep(2_000)
        }
        return nil
    }

    func shutdown() {
        lock.lock()
        let fd = acceptedFD
        acceptedFD = -1
        lock.unlock()
        if fd >= 0 { Darwin.close(fd) }
        Darwin.close(listenFD)
        unlink(path)
    }

    private func serve() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        lock.lock()
        acceptedFD = fd
        lock.unlock()

        readRequest(on: fd)
        answer(on: fd)
    }

    private func readRequest(on fd: Int32) {
        guard let header = readExactly(4, on: fd) else { return }
        let length = header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard length > 0, length < 4_194_304, let payload = readExactly(Int(length), on: fd) else {
            return
        }
        lock.lock()
        receivedPayload = payload
        lock.unlock()
    }

    private func readExactly(_ count: Int, on fd: Int32) -> Data? {
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: count)
        while collected.count < count {
            let read = Darwin.read(fd, &buffer, count - collected.count)
            guard read > 0 else { return nil }
            collected.append(contentsOf: buffer.prefix(read))
        }
        return collected
    }

    private func answer(on fd: Int32) {
        switch behavior {
        case .answer(let payload):
            var frame = Data()
            withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
            frame.append(payload)
            write(frame, on: fd)
            Darwin.close(fd)
        case .rawBytes(let bytes):
            write(bytes, on: fd)
            Darwin.close(fd)
        case .closeWithoutAnswering:
            Darwin.close(fd)
        case .silence:
            break
        }
        lock.lock()
        if case .silence = behavior {} else { acceptedFD = -1 }
        lock.unlock()
    }

    private func write(_ data: Data, on fd: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let sent = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if sent <= 0 { return }
                written += sent
            }
        }
    }
}
