import Darwin
import Foundation

/// Bounded, drop-oldest FIFO for outbound audio frames. Audio is real-time
/// droppable media: when the socket backs up we discard the *oldest* pending
/// chunk rather than let the buffer grow without bound. Control frames never
/// live here — they go through their own never-dropped queue.
struct OutboundAudioBuffer {
    let capacity: Int
    private(set) var frames: [Data] = []
    private(set) var dropped: Int = 0

    init(capacity: Int) {
        precondition(capacity > 0, "audio buffer capacity must be positive")
        self.capacity = capacity
    }

    var isEmpty: Bool { frames.isEmpty }
    var count: Int { frames.count }

    /// Append a frame, discarding the oldest queued frame when already at
    /// capacity. Returns the number of frames dropped to make room (0 or 1).
    @discardableResult
    mutating func append(_ frame: Data) -> Int {
        var droppedNow = 0
        if frames.count >= capacity {
            frames.removeFirst()
            dropped += 1
            droppedNow = 1
        }
        frames.append(frame)
        return droppedNow
    }

    mutating func removeFirst() -> Data? {
        frames.isEmpty ? nil : frames.removeFirst()
    }

    mutating func removeAll() {
        frames.removeAll()
        dropped = 0
    }
}

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

/// Newline-delimited JSON transport over the daemon's AF_UNIX realtime socket.
///
/// The socket fd is non-blocking. Writes are driven by a `DispatchSourceWrite`
/// on the private serial `queue`, so a peer that has stopped reading can never
/// block the queue (the failure that previously wedged the whole app when a
/// blocking `write` parked the queue and a main-thread `queue.sync` piled up
/// behind it). All fd / buffer / dispatch-source state is confined to `queue`;
/// the public surface (`connect`, `send`, `sendAudioChunk`, `close`) is
/// asynchronous and never blocks the caller, and every callback is delivered on
/// `queue` — `MainActorRealtimeDelivery` is what puts them on the main actor.
public final class RealtimeSocketClient: RealtimeTransport, @unchecked Sendable {
    public var onEvent: ((RealtimeServerEvent) -> Void)?
    public var onFailure: ((RealtimeTransportFailure) -> Void)?

    /// Default cap on the pending outbound-audio buffer. The capture tap emits
    /// a chunk per 4800-frame buffer (`AudioController.captureBufferFrames`),
    /// which is ~100 ms of audio at a 48 kHz input rate, so 20 chunks ≈ 2 s of
    /// droppable audio held in reserve before the oldest is discarded.
    public static let defaultMaxPendingAudioChunks = 20

    /// Default deadline for flushing a control frame. Control frames are never
    /// dropped, but if the socket is so backed up that one cannot be written
    /// within this window the connection is declared dead.
    public static let defaultControlFlushDeadline: TimeInterval = 5.0

    /// Default deadline for making *any* outbound write progress while the
    /// audio buffer is saturated. Audio is droppable, so a briefly-full buffer
    /// is normal and never fatal — but a steady call generates no control
    /// frames, so without this a peer that wedges mid-call (e.g. a SIGSTOPed
    /// daemon) is never noticed: audio is dropped forever, the mic stays hot,
    /// and nothing tears down. If the buffer stays full and not one byte drains
    /// for this long, the connection is declared dead. Longer than the control
    /// deadline because a transient capture burst can saturate the buffer
    /// without the link being dead.
    public static let defaultAudioStallDeadline: TimeInterval = 8.0

    /// Log at most one drop line per this many dropped chunks, so a stalled
    /// writer produces a few breadcrumbs instead of a per-chunk flood.
    private static let audioDropLogInterval = 25

    private static let readChunkBytes = 4_096

    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "ai.fermix.realtime.socket")
    private let log = AppLog.logger(.voice)
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeSourceRunning = false

    // Outbound state — all mutated only on `queue`.
    private var outboundControl: [Data] = []
    private var audioBuffer: OutboundAudioBuffer
    private var currentFrame = Data()
    private var currentFrameOffset = 0
    private var currentFrameIsControl = false

    private var controlDeadline: DispatchWorkItem?
    private let controlFlushDeadline: TimeInterval

    private var audioStallDeadline: DispatchWorkItem?
    private let audioStallDeadlineInterval: TimeInterval

    public init(
        maxPendingAudioChunks: Int = RealtimeSocketClient.defaultMaxPendingAudioChunks,
        controlFlushDeadline: TimeInterval = RealtimeSocketClient.defaultControlFlushDeadline,
        audioStallDeadline: TimeInterval = RealtimeSocketClient.defaultAudioStallDeadline
    ) {
        self.audioBuffer = OutboundAudioBuffer(capacity: maxPendingAudioChunks)
        self.controlFlushDeadline = controlFlushDeadline
        self.audioStallDeadlineInterval = audioStallDeadline
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
        controlDeadline?.cancel()
        audioStallDeadline?.cancel()
    }

    /// Opens the socket on the serial queue and reports the outcome there.
    ///
    /// `connect(2)` on an AF_UNIX socket blocks, and the caller is the main
    /// actor, so the whole attempt happens off it: a daemon that is slow to
    /// accept can never stall a window.
    public func connect(
        path: String,
        completion: @escaping (Result<Void, RealtimeConnectFailure>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.closeUnlocked()

            switch self.openConnection(path: path) {
            case .success(let socketFD):
                self.installConnection(fd: socketFD, path: path)
                completion(.success(()))
            case .failure(let failure):
                completion(.failure(failure))
            }
        }
    }

    /// Enqueue a control frame (hello, call_start, interrupt, call_stop, …).
    /// Never dropped; never blocks the caller. If the frame cannot be flushed
    /// within `controlFlushDeadline`, the connection is declared dead.
    public func send(_ event: RealtimeClientEvent) {
        let frame = Self.frame(for: event)
        queue.async { [weak self] in
            self?.enqueueControl(frame)
        }
    }

    /// Enqueue an audio chunk. Real-time droppable: if the outbound buffer is
    /// full the oldest pending chunk is discarded. Never blocks the caller.
    public func sendAudioChunk(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            let frame = Self.frame(for: .audioChunk(base64: data.base64EncodedString()))
            self.enqueueAudio(frame)
        }
    }

    public func close() {
        queue.async { [weak self] in
            self?.closeUnlocked()
        }
    }

    // MARK: - Connection lifecycle (queue-confined)

    private func openConnection(path: String) -> Result<Int32, RealtimeConnectFailure> {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return .failure(RealtimeConnectFailure(errorNumber: errno)) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLength else {
            Darwin.close(socketFD)
            return .failure(RealtimeConnectFailure(errorNumber: ENAMETOOLONG))
        }

        withUnsafeMutableBytes(of: &addr.sun_path) { destination in
            path.utf8CString.withUnsafeBufferPointer { source in
                destination.copyBytes(from: UnsafeRawBufferPointer(source))
            }
        }

        if let failure = disableSigPipe(on: socketFD) {
            Darwin.close(socketFD)
            return .failure(failure)
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(socketFD, socketAddress, size)
            }
        }

        guard result == 0 else {
            let code = errno
            Darwin.close(socketFD)
            return .failure(RealtimeConnectFailure(errorNumber: code))
        }

        // Non-blocking only once connected: a non-blocking `connect` can report
        // EINPROGRESS, and this client has no half-open state to hold that in.
        if let failure = setNonBlocking(on: socketFD) {
            Darwin.close(socketFD)
            return .failure(failure)
        }

        return .success(socketFD)
    }

    /// A write to a peer that has closed returns EPIPE instead of killing the
    /// process.
    private func disableSigPipe(on socketFD: Int32) -> RealtimeConnectFailure? {
        var value: Int32 = 1
        let result = setsockopt(
            socketFD,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &value,
            socklen_t(MemoryLayout<Int32>.size)
        )

        return result == 0 ? nil : RealtimeConnectFailure(errorNumber: errno)
    }

    /// No write can park the serial queue.
    private func setNonBlocking(on socketFD: Int32) -> RealtimeConnectFailure? {
        let flags = fcntl(socketFD, F_GETFL, 0)
        guard flags >= 0 else { return RealtimeConnectFailure(errorNumber: errno) }
        guard fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return RealtimeConnectFailure(errorNumber: errno)
        }

        return nil
    }

    private func installConnection(fd socketFD: Int32, path: String) {
        if fd >= 0 {
            closeUnlocked()
        }

        fd = socketFD
        // The read and write sources both monitor this fd; it is closed only
        // after both have run their cancellation handlers.
        let connectionFD = ConnectionFD(socketFD, sources: 2)
        startReading(closing: connectionFD)
        startWriting(closing: connectionFD)
        log.debug("realtime socket connected fd=\(socketFD, privacy: .public)")
    }

    private func closeUnlocked() {
        cancelWriteSource()

        readSource?.cancel()
        readSource = nil

        controlDeadline?.cancel()
        controlDeadline = nil

        clearAudioStallDeadline()

        outboundControl.removeAll()
        audioBuffer.removeAll()
        currentFrame = Data()
        currentFrameOffset = 0
        currentFrameIsControl = false

        if fd >= 0 {
            log.debug("realtime socket closing fd=\(self.fd, privacy: .public)")
            // Drop our own handle so no further read/write targets it, but let
            // the sources' cancellation handlers do the actual `close()` — the
            // kevents cancelled just above are deregistered asynchronously (see
            // `ConnectionFD`).
            fd = -1
        }
    }

    /// Tear the connection down from within the queue and report the failure.
    /// Used for read EOF/error, write error, framing violations, and both
    /// flush deadlines.
    private func failConnection(_ failure: RealtimeTransportFailure) {
        guard fd >= 0 else { return }
        log.error("realtime socket down: \(String(describing: failure), privacy: .public)")
        let handler = onFailure
        closeUnlocked()
        handler?(failure)
    }

    // MARK: - Outbound (queue-confined)

    private func enqueueControl(_ frame: Data) {
        guard fd >= 0 else {
            log.error("dropping control frame: socket not connected")
            return
        }

        outboundControl.append(frame)
        startControlDeadlineIfNeeded()
        flushOutbound()
    }

    private func enqueueAudio(_ frame: Data) {
        guard fd >= 0 else { return }

        if audioBuffer.append(frame) > 0 {
            noteAudioDrop()
            // Buffer is saturated (a frame was shed). If it stays that way with
            // no write progress, the peer has stopped reading — arm the stall
            // deadline. Write progress clears it in `flushOutbound`.
            startAudioStallDeadlineIfNeeded()
        }

        flushOutbound()
    }

    private func flushOutbound() {
        guard fd >= 0 else { return }

        while true {
            if currentFrame.isEmpty {
                if !outboundControl.isEmpty {
                    currentFrame = outboundControl.removeFirst()
                    currentFrameOffset = 0
                    currentFrameIsControl = true
                } else if let audioFrame = audioBuffer.removeFirst() {
                    currentFrame = audioFrame
                    currentFrameOffset = 0
                    currentFrameIsControl = false
                } else {
                    // Nothing pending — stop listening for writability.
                    suspendWriteSource()
                    clearControlDeadlineIfDrained()
                    return
                }
            }

            switch writeCurrentFrame() {
            case .completed:
                // The socket accepted bytes — the link is alive, so any armed
                // audio-stall deadline no longer applies.
                clearAudioStallDeadline()
                currentFrame = Data()
                currentFrameOffset = 0
                currentFrameIsControl = false
                clearControlDeadlineIfDrained()
                continue
            case .progressed:
                clearAudioStallDeadline()
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

    private func writeCurrentFrame() -> WriteOutcome {
        let remaining = currentFrame.count - currentFrameOffset
        guard remaining > 0 else { return .completed }

        let written = currentFrame.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.write(fd, base.advanced(by: currentFrameOffset), remaining)
        }

        if written > 0 {
            currentFrameOffset += written
            return currentFrameOffset >= currentFrame.count ? .completed : .progressed
        }

        let err = errno
        if written < 0 && (err == EAGAIN || err == EWOULDBLOCK) {
            return .wouldBlock
        }

        return .failed(err)
    }

    // MARK: - Control-flush deadline (queue-confined)

    private var hasPendingControl: Bool {
        if !outboundControl.isEmpty { return true }
        return currentFrameIsControl && currentFrameOffset < currentFrame.count
    }

    private func startControlDeadlineIfNeeded() {
        guard controlDeadline == nil else { return }

        let deadline = DispatchWorkItem { [weak self] in
            self?.controlFlushDeadlineExpired()
        }
        controlDeadline = deadline
        queue.asyncAfter(deadline: .now() + controlFlushDeadline, execute: deadline)
    }

    private func clearControlDeadlineIfDrained() {
        guard !hasPendingControl else { return }
        controlDeadline?.cancel()
        controlDeadline = nil
    }

    private func controlFlushDeadlineExpired() {
        // Cancellation before execution stops this from running; if we do run,
        // the deadline reference is now spent.
        controlDeadline = nil
        guard hasPendingControl else { return }
        failConnection(.controlFlushTimedOut(seconds: controlFlushDeadline))
    }

    // MARK: - Audio-stall deadline (queue-confined)

    private func startAudioStallDeadlineIfNeeded() {
        guard audioStallDeadline == nil else { return }

        let deadline = DispatchWorkItem { [weak self] in
            self?.audioStallDeadlineExpired()
        }
        audioStallDeadline = deadline
        queue.asyncAfter(deadline: .now() + audioStallDeadlineInterval, execute: deadline)
    }

    private func clearAudioStallDeadline() {
        audioStallDeadline?.cancel()
        audioStallDeadline = nil
    }

    private func audioStallDeadlineExpired() {
        // The deadline reference is spent once it fires. Reaching here means no
        // write made progress for the whole window while audio was backed up —
        // the peer stopped reading mid-call.
        audioStallDeadline = nil
        failConnection(.audioStalled(seconds: audioStallDeadlineInterval))
    }

    // MARK: - Read path (queue-confined)

    private func startReading(closing connectionFD: ConnectionFD) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var inbound = RealtimeInboundBuffer()

        source.setEventHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            var chunk = [UInt8](repeating: 0, count: Self.readChunkBytes)
            let count = Darwin.read(self.fd, &chunk, chunk.count)

            if count > 0 {
                self.deliver(Data(chunk.prefix(count)), into: &inbound)
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

    /// Frames what was read and hands each event up. A frame this client
    /// refuses to hold, or one that is not a wire event at all, ends the
    /// connection: it is a contract violation, not a line to skip.
    private func deliver(_ bytes: Data, into inbound: inout RealtimeInboundBuffer) {
        do {
            try inbound.append(bytes) { [weak self] event in
                self?.onEvent?(event)
            }
        } catch let failure as RealtimeDecodeFailure {
            inbound.reset()
            failConnection(.framingViolation(failure))
        } catch {
            inbound.reset()
            failConnection(.framingViolation(.malformedJSON))
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

    private func noteAudioDrop() {
        let total = audioBuffer.dropped
        if total == 1 || total % Self.audioDropLogInterval == 0 {
            log.error("outbound audio buffer full, dropped oldest chunk (total \(total, privacy: .public))")
        }
    }

    /// A client event is a closed set of encodable values, so a frame that
    /// cannot be produced is a programming defect rather than a wire condition.
    private static func frame(for event: RealtimeClientEvent) -> Data {
        do {
            return try event.frame()
        } catch {
            preconditionFailure("realtime event \(event.wireType) could not be encoded: \(error)")
        }
    }

    #if DEBUG
    /// Test-only: cumulative count of audio chunks the bounded outbound buffer
    /// has dropped. Read on the socket queue; never called by production code.
    func testOnlyAudioDropCount() -> Int {
        queue.sync { audioBuffer.dropped }
    }
    #endif
}
