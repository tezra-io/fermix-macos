import Darwin
import Foundation
import os

/// Owns a connected socket fd and closes it exactly once — only after every
/// dispatch source that was watching it has run its cancellation handler.
/// libdispatch deregisters a source's kevent asynchronously (on its manager
/// thread), so closing the fd the instant `cancel()` returns risks a deferred
/// `EV_DELETE` landing on a *new* source that has since registered for a reused
/// fd number, silently killing the next connection. Every call happens on the
/// socket's serial queue, so the countdown needs no locking.
private final class ConnectionFD {
    let value: Int32
    private var pendingCancellations: Int

    init(_ value: Int32, sources: Int) {
        precondition(sources > 0, "must wait on at least one source")
        self.value = value
        self.pendingCancellations = sources
    }

    /// Call once from each source's cancellation handler. Closes the fd on the
    /// final outstanding cancellation.
    func sourceCancelled() {
        pendingCancellations -= 1
        guard pendingCancellations == 0 else { return }
        Darwin.close(value)
    }
}

/// Sizes that are the reader's and the log's, not the owning wire's.
private enum LineSocketTuning {
    static let readChunkBytes = 4_096

    /// Log at most one drop line per this many dropped lines, so a stalled
    /// writer produces a few breadcrumbs instead of a per-line flood.
    static let droppedLineLogInterval = 25
}

/// Newline-delimited lines over an AF_UNIX stream socket, decoded by the wire
/// that owns them.
///
/// The socket fd is non-blocking. Writes are driven by a `DispatchSourceWrite`
/// on the private serial `queue`, so a peer that has stopped reading can never
/// block the queue (the failure that previously wedged the whole app when a
/// blocking `write` parked the queue and a main-thread `queue.sync` piled up
/// behind it). All fd / buffer / dispatch-source state is confined to `queue`;
/// the public surface (`connect`, `send`, `sendDroppable`, `close`) is
/// asynchronous and never blocks the caller, and every callback is delivered on
/// `queue`, so the owner decides where its consumers run.
public final class LineSocketClient<Message: Sendable, DecodeFailure: Error & Equatable & Sendable>:
    LineSocketTransport, @unchecked Sendable
{
    public var onMessage: ((Message) -> Void)?
    public var onFailure: ((LineSocketFailure<DecodeFailure>) -> Void)?

    private let name: String
    private let log: Logger
    private let inboundLimits: LineInboundLimits
    private let outboundLimits: LineOutboundLimits
    private let decode: @Sendable (Data) throws(DecodeFailure) -> Message

    private var fd: Int32 = -1
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeSourceRunning = false

    // Outbound state — all mutated only on `queue`.
    private var reliableLines: [Data] = []
    private var droppableLines: DroppableLineBuffer
    private var currentLine = Data()
    private var currentLineOffset = 0
    private var currentLineIsReliable = false

    private var flushDeadline: DispatchWorkItem?
    private var stallDeadline: DispatchWorkItem?

    /// `name` labels the queue and every log line, so two wires on one process
    /// read apart in Console.
    public init(
        name: String,
        log: Logger,
        inbound: LineInboundLimits,
        outbound: LineOutboundLimits,
        decode: @escaping @Sendable (Data) throws(DecodeFailure) -> Message
    ) {
        self.name = name
        self.log = log
        self.inboundLimits = inbound
        self.outboundLimits = outbound
        self.decode = decode
        self.queue = DispatchQueue(label: "ai.fermix.\(name).socket")
        self.droppableLines = DroppableLineBuffer(capacity: outbound.maximumPendingDroppableLines)
    }

    deinit {
        // If the connection was never explicitly closed, dispose the sources
        // here. Releasing a *suspended* dispatch source traps libdispatch, so
        // balance the write source's suspend before it is released.
        //
        // The fd itself is closed by the sources' cancellation handlers (see
        // `ConnectionFD`), never directly here — libdispatch keeps a cancelled
        // source (and the `ConnectionFD` its handler captured) alive until the
        // handler runs, so the fd is closed exactly once after both kevents are
        // deregistered, even though `self` is already gone.
        if let source = writeSource, !writeSourceRunning {
            source.resume()
        }
        writeSource?.cancel()
        readSource?.cancel()
        flushDeadline?.cancel()
        stallDeadline?.cancel()
    }

    /// Opens the socket on the serial queue and reports the outcome there.
    ///
    /// `connect(2)` on an AF_UNIX socket blocks, and the caller is the main
    /// actor, so the whole attempt happens off it: a daemon that is slow to
    /// accept can never stall a window.
    public func connect(
        path: String,
        completion: @escaping (Result<Void, LineSocketConnectFailure>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.closeUnlocked()

            let socketFD: Int32
            do throws(LineSocketConnectFailure) {
                socketFD = try Self.openConnection(path: path)
            } catch {
                completion(.failure(error))
                return
            }

            self.installConnection(fd: socketFD)
            completion(.success(()))
        }
    }

    /// Enqueue a line that must arrive. Never dropped; never blocks the caller.
    /// If it cannot be flushed within the flush deadline, the connection is
    /// declared dead.
    public func send(_ line: Data) {
        queue.async { [weak self] in
            self?.enqueueReliable(Self.terminated(line))
        }
    }

    /// Enqueue a droppable line. If the outbound buffer is full the oldest
    /// pending droppable line is discarded. Never blocks the caller.
    public func sendDroppable(_ line: Data) {
        queue.async { [weak self] in
            self?.enqueueDroppable(Self.terminated(line))
        }
    }

    /// For a real-time producer: the line is produced on the socket's queue,
    /// not the caller's thread; if the buffer is full the oldest pending
    /// droppable line is discarded exactly as with `sendDroppable(_:)`.
    public func sendDroppable(producing line: @escaping @Sendable () -> Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.enqueueDroppable(Self.terminated(line()))
        }
    }

    public func close() {
        queue.async { [weak self] in
            self?.closeUnlocked()
        }
    }

    // MARK: - Opening a socket (no instance state)

    private static func openConnection(path: String) throws(LineSocketConnectFailure) -> Int32 {
        var address = try socketAddress(for: path)

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw .system(errno: errno) }

        do throws(LineSocketConnectFailure) {
            try disableSigPipe(on: socketFD)
            try connectSocket(socketFD, to: &address)
            // Non-blocking only once connected: a non-blocking `connect` can
            // report EINPROGRESS, and this client has no half-open state to
            // hold that in.
            try setNonBlocking(on: socketFD)
        } catch {
            Darwin.close(socketFD)
            throw error
        }

        return socketFD
    }

    /// The address for `path`, refused before any socket exists when the path
    /// and its terminator do not fit `sun_path` (104 bytes on Darwin).
    private static func socketAddress(for path: String) throws(LineSocketConnectFailure) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let maximum = MemoryLayout.size(ofValue: address.sun_path) - 1
        let bytes = path.utf8.count
        guard bytes <= maximum else { throw .pathTooLong(bytes: bytes, maximum: maximum) }

        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            path.utf8CString.withUnsafeBufferPointer { source in
                destination.copyBytes(from: UnsafeRawBufferPointer(source))
            }
        }

        return address
    }

    /// A write to a peer that has closed returns EPIPE instead of killing the
    /// process.
    private static func disableSigPipe(on socketFD: Int32) throws(LineSocketConnectFailure) {
        var value: Int32 = 1
        let result = setsockopt(
            socketFD,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &value,
            socklen_t(MemoryLayout<Int32>.size)
        )

        guard result == 0 else { throw .system(errno: errno) }
    }

    private static func connectSocket(
        _ socketFD: Int32,
        to address: inout sockaddr_un
    ) throws(LineSocketConnectFailure) {
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(socketFD, socketAddress, size)
            }
        }

        guard result == 0 else { throw .system(errno: errno) }
    }

    /// No write can park the serial queue.
    private static func setNonBlocking(on socketFD: Int32) throws(LineSocketConnectFailure) {
        let flags = fcntl(socketFD, F_GETFL, 0)
        guard flags >= 0 else { throw .system(errno: errno) }
        guard fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) == 0 else { throw .system(errno: errno) }
    }

    private static func terminated(_ line: Data) -> Data {
        var framed = line
        framed.append(0x0A)
        return framed
    }

    // MARK: - Connection lifecycle (queue-confined)

    private func installConnection(fd socketFD: Int32) {
        fd = socketFD
        // The read and write sources both monitor this fd; it is closed only
        // after both have run their cancellation handlers.
        let connectionFD = ConnectionFD(socketFD, sources: 2)
        startReading(closing: connectionFD)
        startWriting(closing: connectionFD)
        log.debug("\(self.name, privacy: .public) socket connected fd=\(socketFD, privacy: .public)")
    }

    private func closeUnlocked() {
        cancelWriteSource()

        readSource?.cancel()
        readSource = nil

        flushDeadline?.cancel()
        flushDeadline = nil

        clearStallDeadline()

        reliableLines.removeAll()
        droppableLines.removeAll()
        currentLine = Data()
        currentLineOffset = 0
        currentLineIsReliable = false

        if fd >= 0 {
            log.debug("\(self.name, privacy: .public) socket closing fd=\(self.fd, privacy: .public)")
            // Drop our own handle so no further read/write targets it, but let
            // the sources' cancellation handlers do the actual `close()` — the
            // kevents cancelled just above are deregistered asynchronously (see
            // `ConnectionFD`).
            fd = -1
        }
    }

    /// Tear the connection down from within the queue and report the failure.
    /// Used for read EOF/error, write error, framing and decode failures, and
    /// both write deadlines.
    private func failConnection(_ failure: LineSocketFailure<DecodeFailure>) {
        guard fd >= 0 else { return }
        log.error("\(self.name, privacy: .public) socket down: \(String(describing: failure), privacy: .public)")
        let handler = onFailure
        closeUnlocked()
        handler?(failure)
    }

    // MARK: - Outbound (queue-confined)

    private func enqueueReliable(_ line: Data) {
        guard fd >= 0 else {
            log.error("dropping a line: \(self.name, privacy: .public) socket not connected")
            return
        }

        reliableLines.append(line)
        startFlushDeadlineIfNeeded()
        flushOutbound()
    }

    private func enqueueDroppable(_ line: Data) {
        guard fd >= 0 else { return }

        if droppableLines.append(line) > 0 {
            noteDroppedLine()
            // Buffer is saturated (a line was shed). If it stays that way with
            // no write progress, the peer has stopped reading — arm the stall
            // deadline. Write progress clears it in `flushOutbound`.
            startStallDeadlineIfNeeded()
        }

        flushOutbound()
    }

    private func flushOutbound() {
        guard fd >= 0 else { return }

        while true {
            if currentLine.isEmpty {
                if !reliableLines.isEmpty {
                    currentLine = reliableLines.removeFirst()
                    currentLineOffset = 0
                    currentLineIsReliable = true
                } else if let droppableLine = droppableLines.removeFirst() {
                    currentLine = droppableLine
                    currentLineOffset = 0
                    currentLineIsReliable = false
                } else {
                    // Nothing pending — stop listening for writability.
                    suspendWriteSource()
                    clearFlushDeadlineIfDrained()
                    return
                }
            }

            switch writeCurrentLine() {
            case .completed:
                // The socket accepted bytes — the link is alive, so any armed
                // stall deadline no longer applies.
                clearStallDeadline()
                currentLine = Data()
                currentLineOffset = 0
                currentLineIsReliable = false
                clearFlushDeadlineIfDrained()
                continue
            case .progressed:
                clearStallDeadline()
                continue
            case .wouldBlock:
                // Kernel send buffer is full; wake when the socket drains.
                resumeWriteSource()
                return
            case let .failed(code):
                failConnection(.writeFailed(errno: code))
                return
            }
        }
    }

    private enum WriteOutcome {
        case completed
        case progressed
        case wouldBlock
        case failed(Int32)
    }

    private func writeCurrentLine() -> WriteOutcome {
        let remaining = currentLine.count - currentLineOffset
        guard remaining > 0 else { return .completed }

        let written = currentLine.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.write(fd, base.advanced(by: currentLineOffset), remaining)
        }

        if written > 0 {
            currentLineOffset += written
            return currentLineOffset >= currentLine.count ? .completed : .progressed
        }

        let err = errno
        if written < 0 && (err == EAGAIN || err == EWOULDBLOCK) {
            return .wouldBlock
        }

        return .failed(err)
    }

    // MARK: - Flush deadline (queue-confined)

    private var hasPendingReliableLine: Bool {
        if !reliableLines.isEmpty { return true }
        return currentLineIsReliable && currentLineOffset < currentLine.count
    }

    private func startFlushDeadlineIfNeeded() {
        guard flushDeadline == nil else { return }

        let deadline = DispatchWorkItem { [weak self] in
            self?.flushDeadlineExpired()
        }
        flushDeadline = deadline
        queue.asyncAfter(deadline: .now() + outboundLimits.flushDeadline, execute: deadline)
    }

    private func clearFlushDeadlineIfDrained() {
        guard !hasPendingReliableLine else { return }
        flushDeadline?.cancel()
        flushDeadline = nil
    }

    private func flushDeadlineExpired() {
        // Cancellation before execution stops this from running; if we do run,
        // the deadline reference is now spent.
        flushDeadline = nil
        guard hasPendingReliableLine else { return }
        failConnection(.flushTimedOut(seconds: outboundLimits.flushDeadline))
    }

    // MARK: - Stall deadline (queue-confined)

    private func startStallDeadlineIfNeeded() {
        guard stallDeadline == nil else { return }

        let deadline = DispatchWorkItem { [weak self] in
            self?.stallDeadlineExpired()
        }
        stallDeadline = deadline
        queue.asyncAfter(deadline: .now() + outboundLimits.stallDeadline, execute: deadline)
    }

    private func clearStallDeadline() {
        stallDeadline?.cancel()
        stallDeadline = nil
    }

    private func stallDeadlineExpired() {
        // The deadline reference is spent once it fires. Reaching here means no
        // write made progress for the whole window while droppable lines were
        // backed up — the peer stopped reading.
        stallDeadline = nil
        failConnection(.writeStalled(seconds: outboundLimits.stallDeadline))
    }

    // MARK: - Read path (queue-confined)

    private func startReading(closing connectionFD: ConnectionFD) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var inbound = LineInboundBuffer(limits: inboundLimits, decode: decode)

        source.setEventHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            var chunk = [UInt8](repeating: 0, count: LineSocketTuning.readChunkBytes)
            let count = Darwin.read(self.fd, &chunk, chunk.count)

            if count > 0 {
                self.receive(Data(chunk.prefix(count)), into: &inbound)
                return
            }

            if count < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    return
                }
                self.failConnection(.readFailed(errno: err))
                return
            }

            // count == 0 → peer closed the socket (EOF).
            self.failConnection(.peerClosed)
        }

        source.setCancelHandler { connectionFD.sourceCancelled() }
        readSource = source
        source.resume()
    }

    /// Frames what was read and hands each decoded line up. A run this client
    /// refuses to hold, or a line the owner cannot decode, ends the connection:
    /// it is a contract violation, not a line to skip.
    private func receive(_ bytes: Data, into inbound: inout LineInboundBuffer<Message, DecodeFailure>) {
        do throws(LineSocketFailure<DecodeFailure>) {
            try inbound.append(bytes) { message in
                onMessage?(message)
            }
        } catch {
            inbound.reset()
            failConnection(error)
        }
    }

    // MARK: - Write source (queue-confined)

    private func startWriting(closing connectionFD: ConnectionFD) {
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.flushOutbound()
        }
        source.setCancelHandler { connectionFD.sourceCancelled() }
        writeSource = source
        // Created suspended; resumed only when a write cannot complete.
        writeSourceRunning = false
    }

    private func resumeWriteSource() {
        guard let source = writeSource, !writeSourceRunning else { return }
        writeSourceRunning = true
        source.resume()
    }

    private func suspendWriteSource() {
        guard let source = writeSource, writeSourceRunning else { return }
        writeSourceRunning = false
        source.suspend()
    }

    private func cancelWriteSource() {
        guard let source = writeSource else { return }
        source.setEventHandler {}
        if !writeSourceRunning {
            // A suspended dispatch source traps libdispatch if released while
            // suspended; balance the suspend before cancelling.
            writeSourceRunning = true
            source.resume()
        }
        source.cancel()
        writeSource = nil
        writeSourceRunning = false
    }

    // MARK: - Helpers

    private func noteDroppedLine() {
        let total = droppableLines.dropped
        guard total == 1 || total % LineSocketTuning.droppedLineLogInterval == 0 else { return }

        log.error(
            "\(self.name, privacy: .public) droppable buffer full, dropped oldest (total \(total, privacy: .public))"
        )
    }

    #if DEBUG
    /// Test-only: cumulative count of droppable lines the bounded outbound
    /// buffer has dropped. Read on the socket queue; never called by
    /// production code.
    func testOnlyDroppedLineCount() -> Int {
        queue.sync { droppableLines.dropped }
    }
    #endif
}
