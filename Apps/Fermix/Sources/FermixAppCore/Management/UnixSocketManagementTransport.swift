import Darwin
import Foundation

/// One exchange over the daemon's `daemon.sock`.
///
/// The socket is non-blocking and every wait is a `poll` against a single
/// deadline computed from the caller's timeout, so a peer that accepts and then
/// says nothing cannot park the call. The connection is opened for one request
/// and closed on every path, including every failure.
public struct UnixSocketManagementTransport: ManagementTransport {
    private let socketPath: String
    private let limits: ManagementLimits
    private let queue: DispatchQueue

    public init(socketPath: String, limits: ManagementLimits) {
        self.socketPath = socketPath
        self.limits = limits
        self.queue = DispatchQueue(label: "io.tezra.fermix.management.socket", qos: .userInitiated)
    }

    public func exchange(_ payload: Data, timeout: Duration) async throws -> Data {
        // Measured before anything is opened: an oversized request never
        // reaches the socket, so it fails with its size rather than an opaque
        // transport error.
        let header = try ManagementFraming.header(
            payloadLength: payload.count,
            limit: limits.maxFrameBytes
        )

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(
                    with: Result { try perform(header: header, payload: payload, timeout: timeout) }
                )
            }
        }
    }

    // MARK: - One exchange

    private func perform(header: Data, payload: Data, timeout: Duration) throws -> Data {
        let deadline = try ManagementDeadline(timeout: timeout)
        let descriptor = try openSocket()
        defer { Darwin.close(descriptor) }

        try connect(descriptor, deadline: deadline)
        try writeAll(header + payload, to: descriptor, deadline: deadline)

        let responseHeader = try read(
            ManagementFraming.headerLength,
            from: descriptor,
            deadline: deadline,
            emptyMeansClosed: true
        )
        let length = try ManagementFraming.payloadLength(
            fromHeader: responseHeader,
            limit: limits.maxFrameBytes
        )
        return try read(length, from: descriptor, deadline: deadline, emptyMeansClosed: false)
    }

    private func openSocket() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ManagementTransportFailure.connectFailed(errno: errno)
        }

        var enabled: Int32 = 1
        let optionSize = socklen_t(MemoryLayout<Int32>.size)
        let configured = setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, optionSize
        ) == 0 && makeNonBlocking(descriptor)

        guard configured else {
            let code = errno
            Darwin.close(descriptor)
            throw ManagementTransportFailure.connectFailed(errno: code)
        }
        return descriptor
    }

    private func makeNonBlocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0 else { return false }
        return fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private func connect(_ descriptor: Int32, deadline: ManagementDeadline) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ManagementTransportFailure.socketPathTooLong(path: socketPath)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            socketPath.utf8CString.withUnsafeBufferPointer { source in
                destination.copyBytes(from: UnsafeRawBufferPointer(source))
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let outcome = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(descriptor, socketAddress, size)
            }
        }
        if outcome == 0 { return }

        let code = errno
        guard code == EINPROGRESS else { throw connectFailure(code) }

        try wait(descriptor, for: Int16(POLLOUT), deadline: deadline)
        var pending: Int32 = 0
        var pendingSize = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &pending, &pendingSize) == 0 else {
            throw ManagementTransportFailure.connectFailed(errno: errno)
        }
        guard pending == 0 else { throw connectFailure(pending) }
    }

    /// A missing socket file and a stale one with nobody listening are different
    /// situations for the operator, so they stay different errors.
    private func connectFailure(_ code: Int32) -> ManagementTransportFailure {
        switch code {
        case ENOENT:
            return .socketMissing(path: socketPath)
        case ECONNREFUSED:
            return .daemonNotListening(path: socketPath)
        default:
            return .connectFailed(errno: code)
        }
    }

    // MARK: - Bytes

    private func writeAll(
        _ data: Data,
        to descriptor: Int32,
        deadline: ManagementDeadline
    ) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }

            let code = errno
            guard written < 0, code == EAGAIN || code == EWOULDBLOCK else {
                throw ManagementTransportFailure.writeFailed(errno: code)
            }
            try wait(descriptor, for: Int16(POLLOUT), deadline: deadline)
        }
    }

    private func read(
        _ count: Int,
        from descriptor: Int32,
        deadline: ManagementDeadline,
        emptyMeansClosed: Bool
    ) throws -> Data {
        var collected = Data(capacity: count)
        var buffer = [UInt8](repeating: 0, count: count)

        while collected.count < count {
            let received = Darwin.read(descriptor, &buffer, count - collected.count)
            if received > 0 {
                collected.append(contentsOf: buffer.prefix(received))
                continue
            }
            if received == 0 {
                throw endOfStream(
                    expected: count,
                    received: collected.count,
                    emptyMeansClosed: emptyMeansClosed
                )
            }

            let code = errno
            guard code == EAGAIN || code == EWOULDBLOCK else {
                throw ManagementTransportFailure.readFailed(errno: code)
            }
            try wait(descriptor, for: Int16(POLLIN), deadline: deadline)
        }
        return collected
    }

    private func endOfStream(
        expected: Int,
        received: Int,
        emptyMeansClosed: Bool
    ) -> ManagementTransportFailure {
        if received == 0 && emptyMeansClosed {
            return .peerClosedBeforeResponse
        }
        return .shortFrame(expected: expected, received: received)
    }

    private func wait(_ descriptor: Int32, for events: Int16, deadline: ManagementDeadline) throws {
        var poller = pollfd(fd: descriptor, events: events, revents: 0)
        while true {
            let remaining = try deadline.remainingMilliseconds()
            let ready = poll(&poller, 1, remaining)
            if ready > 0 { return }
            if ready == 0 { throw ManagementTransportFailure.timedOut(after: deadline.timeout) }

            let code = errno
            guard code == EINTR else { throw ManagementTransportFailure.pollFailed(errno: code) }
        }
    }
}

/// One monotonic deadline for a whole exchange. Every wait subtracts from it, so
/// a peer cannot extend the call by answering slowly in many small steps.
struct ManagementDeadline {
    /// A ceiling on any single management exchange. Callers that need to wait
    /// longer (activation waits up to 90 seconds) retry the call rather than
    /// hold one socket open.
    static let maximum: Duration = .seconds(600)

    let timeout: Duration
    private let expiry: DispatchTime

    init(timeout: Duration) throws {
        guard timeout > .zero, timeout <= Self.maximum else {
            throw ManagementTransportFailure.invalidTimeout(timeout)
        }
        self.timeout = timeout
        let components = timeout.components
        let nanoseconds = components.seconds * 1_000_000_000
            + components.attoseconds / 1_000_000_000
        self.expiry = DispatchTime.now() + .nanoseconds(Int(nanoseconds))
    }

    func remainingMilliseconds() throws -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard expiry.uptimeNanoseconds > now else {
            throw ManagementTransportFailure.timedOut(after: timeout)
        }
        let remaining = (expiry.uptimeNanoseconds - now) / 1_000_000
        return Int32(min(remaining, UInt64(Int32.max)))
    }
}
