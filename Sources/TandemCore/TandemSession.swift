import Foundation

/// One request lane per connection. Feature services may share this session but
/// must serialize requests. ACK processing never waits for a feature consumer.
@MainActor
public final class TandemSession {
    /// Receives deduplicated, non-quarantined data in wire order, including
    /// matched replies, before awaiting request continuations can resume.
    public var onMessage: ((Frame) -> Void)?
    public var onNotification: ((Frame) -> Void)?
    public var onClosed: ((Error) -> Void)?
    public var onLog: ((String) -> Void)?
    public private(set) var isOpen = false
    private let transport: TandemTransport
    private let timeout: TimeInterval
    private let ackTimeout: TimeInterval
    private let retries: Int
    private var parser = FrameParser()
    private var sequence: UInt8 = 0
    private var lastReceivedSequence: UInt8?
    private var epoch = UUID()
    private var inbox: [Frame] = []
    private var draining = false
    private var quarantined: Set<ReplyMatcher> = []
    private var pending: Pending?

    private final class Pending {
        let id: UUID
        let frame: Frame
        let matcher: ReplyMatcher
        let continuation: CheckedContinuation<Frame, Error>
        var timer: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var validateBeforeSend: (() throws -> Void)?
        var acknowledged = false
        var reply: Frame?
        init(id: UUID, frame: Frame, matcher: ReplyMatcher, continuation: CheckedContinuation<Frame, Error>) {
            self.id = id; self.frame = frame; self.matcher = matcher; self.continuation = continuation
        }
    }

    public init(transport: TandemTransport, timeout: TimeInterval = 5,
                ackTimeout: TimeInterval = 0.8, retries: Int = 2) {
        self.transport = transport; self.timeout = timeout; self.ackTimeout = ackTimeout; self.retries = retries
    }

    public func open() async throws {
        stop()
        let currentEpoch = epoch
        parser = FrameParser(); sequence = 0; lastReceivedSequence = nil
        quarantined.removeAll()
        transport.onBytes = { [weak self] bytes in
            guard let self, self.epoch == currentEpoch else { return }
            self.receive(bytes)
        }
        transport.onDisconnect = { [weak self] error in
            guard let self, self.epoch == currentEpoch else { return }
            self.close(error ?? TandemError.disconnected)
        }
        do {
            try await transport.connect()
            try Task.checkCancellation()
            guard epoch == currentEpoch else { throw TandemError.disconnected }
            isOpen = true
        } catch {
            if epoch == currentEpoch { close(error) }
            throw error
        }
    }

    public func initialize() async throws -> ProtocolGeneration {
        let reply = try await request(table: 0x0c, payload: [0, 0],
                                      matching: ReplyMatcher(table: 0x0c, command: 1, type: 0))
        return try ProtocolGeneration.detect(reply.payload)
    }

    public func stop() { close(TandemError.disconnected, notify: false) }

    public func request(table: UInt8, payload: [UInt8], matching matcher: ReplyMatcher,
                        validateBeforeSend: (() throws -> Void)? = nil) async throws -> Frame {
        try Task.checkCancellation()
        guard isOpen else { throw TandemError.disconnected }
        guard pending == nil else { throw TandemError.busy }
        guard !quarantined.contains(matcher) else {
            throw TandemError.timedOut("this response earlier; reconnect before retrying")
        }
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let frame = Frame(dataType: table, sequence: sequence, payload: payload)
                sequence = 1 - sequence
                let operation = Pending(id: id, frame: frame, matcher: matcher, continuation: continuation)
                operation.validateBeforeSend = validateBeforeSend
                pending = operation
                operation.deadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(max(0.001, self?.timeout ?? 5) * 1_000_000_000)) }
                    catch { return }
                    guard let self, self.pending?.id == id else { return }
                    if !operation.acknowledged { self.close(TandemError.timedOut("Bluetooth acknowledgement or write")) }
                    else {
                        self.quarantined.insert(operation.matcher)
                        self.finish(.failure(TandemError.timedOut("device response")))
                    }
                }
                operation.timer = Task { [weak self] in await self?.runRequest(id: id) }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in
                guard self?.pending?.id == id else { return }
                self?.close(CancellationError())
            }
        })
    }

    private func runRequest(id: UUID) async {
        guard let operation = pending, operation.id == id else { return }
        // Validate once immediately before the first transmission. A rejected
        // unsent command neither consumes a sequence nor closes the connection.
        do { try operation.validateBeforeSend?() }
        catch {
            sequence = operation.frame.sequence
            finish(.failure(error))
            return
        }
        operation.validateBeforeSend = nil
        let currentEpoch = epoch
        var transmissions = 0
        do {
            while pending?.id == id {
                if !operation.acknowledged {
                    guard transmissions <= retries else { close(TandemError.timedOut("Bluetooth acknowledgement")); return }
                    transmissions += 1
                    try await send(operation.frame)
                }
                try await Task.sleep(nanoseconds: UInt64(max(0.001, ackTimeout) * 1_000_000_000))
                guard pending?.id == id else { return }

            }
        } catch is CancellationError {
            // finish/close cancels the timer. Caller cancellation uses close().
        } catch {
            if epoch == currentEpoch, pending?.id == id { close(error) }
        }
    }

    private func receive(_ bytes: [UInt8]) {
        inbox += parser.feed(bytes)
        guard inbox.count <= 256 else { close(TandemError.malformed("receive queue overflow")); return }
        guard !draining else { return }
        draining = true
        let currentEpoch = epoch
        Task { [weak self] in
            guard let self else { return }
            while self.epoch == currentEpoch, !self.inbox.isEmpty {
                let frame = self.inbox.removeFirst()
                self.onLog?("RX " + Self.hex(FrameCodec.encode(frame)))
                if frame.dataType == 1 {
                    if let operation = self.pending, frame.sequence == 1 - operation.frame.sequence {
                        operation.acknowledged = true
                        if let reply = operation.reply { self.finish(.success(reply)) }
                    }
                    continue
                }
                do { try await self.send(.ack(for: frame.sequence)) }
                catch {
                    if self.epoch == currentEpoch { self.close(error) }
                    return
                }
                guard self.epoch == currentEpoch else { return }
                guard self.lastReceivedSequence != frame.sequence else { continue }
                self.lastReceivedSequence = frame.sequence
                if self.quarantined.contains(where: { $0.matches(frame) }) { continue }
                self.onMessage?(frame)
                guard self.epoch == currentEpoch else { return }
                if let operation = self.pending, operation.matcher.matches(frame) {
                    operation.reply = frame
                    if operation.acknowledged { self.finish(.success(frame)) }
                } else { self.onNotification?(frame) }
            }
            if self.epoch == currentEpoch { self.draining = false }
        }
    }

    private func send(_ frame: Frame) async throws {
        let bytes = FrameCodec.encode(frame)
        onLog?("TX " + Self.hex(bytes))
        try await transport.write(bytes)
    }

    private func finish(_ result: Result<Frame, Error>) {
        guard let operation = pending else { return }
        pending = nil
        operation.timer?.cancel()
        operation.deadline?.cancel()
        operation.continuation.resume(with: result)
    }

    private func close(_ error: Error, notify: Bool = true) {
        let wasActive = isOpen || pending != nil
        isOpen = false; epoch = UUID(); inbox.removeAll(); draining = false
        transport.onBytes = nil; transport.onDisconnect = nil
        transport.disconnect()
        finish(.failure(error))
        if notify && wasActive { onClosed?(error) }
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
