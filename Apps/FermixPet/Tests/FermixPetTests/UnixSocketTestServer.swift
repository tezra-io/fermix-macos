import Darwin
import Foundation

/// Minimal AF_UNIX test peer for `RealtimeSocketClient`. Binds a listening
/// socket at a temp path, accepts one connection on a background queue, and
/// either drains reads or (deliberately) never reads — the latter is how we
/// reproduce a wedged writer.
final class UnixSocketTestServer {
    let path: String

    private let listenFD: Int32
    private let drainReads: Bool
    private let acceptQueue = DispatchQueue(label: "test.unix.accept")
    private let lock = NSLock()
    private var acceptedFD: Int32 = -1
    private var received = Data()

    init(drainReads: Bool) throws {
        self.drainReads = drainReads

        let base = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fermixpet-\(UUID().uuidString.prefix(8)).sock")
        self.path = base

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
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, size)
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard listen(fd, 1) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    private func acceptLoop() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }

        lock.lock()
        acceptedFD = fd
        lock.unlock()

        guard drainReads else { return }

        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            lock.lock()
            received.append(contentsOf: buffer.prefix(count))
            lock.unlock()
        }
    }

    /// Bytes read from the client so far (only meaningful when `drainReads`).
    func receivedData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    /// Block until the incoming connection is accepted, or the deadline passes.
    @discardableResult
    func waitForAccept(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let ready = acceptedFD >= 0
            lock.unlock()
            if ready { return true }
            usleep(5_000)
        }
        return false
    }

    /// Write raw bytes back to the client (used to exercise the read path).
    func writeToClient(_ data: Data) {
        lock.lock()
        let fd = acceptedFD
        lock.unlock()
        guard fd >= 0 else { return }

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let sent = write(fd, base.advanced(by: written), data.count - written)
                if sent <= 0 { break }
                written += sent
            }
        }
    }

    /// Close only the accepted (server-side) fd, so the client observes EOF.
    func closeAcceptedConnection() {
        lock.lock()
        let fd = acceptedFD
        acceptedFD = -1
        lock.unlock()
        if fd >= 0 { Darwin.close(fd) }
    }

    func shutdown() {
        closeAcceptedConnection()
        Darwin.close(listenFD)
        unlink(path)
    }
}
