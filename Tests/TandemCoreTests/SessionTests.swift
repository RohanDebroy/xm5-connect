import XCTest
@testable import TandemCore

@MainActor
final class MemoryTransport: TandemTransport {
    var onBytes: (([UInt8]) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var writes: [[UInt8]] = []
    var responder: ((Frame) -> Void)?
    var isOpen = false
    var failWrites = false
    var writeDelay: UInt64 = 0
    var connectHook: (() async throws -> Void)?
    var writeHook: (([UInt8]) async throws -> Void)?
    func connect() async throws {
        try await connectHook?()
        isOpen = true
    }
    func disconnect() { isOpen = false }
    func write(_ bytes: [UInt8]) async throws {
        try await writeHook?(bytes)
        if writeDelay > 0 { try await Task.sleep(nanoseconds: writeDelay) }
        if failWrites { throw TandemError.transport("write failed") }
        writes.append(bytes)
        var parser = FrameParser()
        if let frame = parser.feed(bytes).first { responder?(frame) }
    }
    func deliver(_ frame: Frame) { onBytes?(FrameCodec.encode(frame)) }
}

@MainActor
final class SessionTests: XCTestCase {
    func testRejectedPreflightDoesNotTransmitOrConsumeSequence() async throws {
        let transport = MemoryTransport()
        let session = TandemSession(transport: transport)
        try await session.open()
        do {
            _ = try await session.request(table: 0x0c, payload: [0, 0],
                matching: .init(table: 0x0c, command: 1, type: 0),
                validateBeforeSend: { throw TandemError.busy })
            XCTFail("Stale command was accepted")
        } catch {}
        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertTrue(session.isOpen)
        transport.responder = { frame in
            guard frame.dataType != 1 else { return }
            XCTAssertEqual(frame.sequence, 0)
            transport.deliver(.ack(for: frame.sequence))
            transport.deliver(Frame(dataType: 0x0c, sequence: 0, payload: [1, 0, 3, 0, 0, 0, 0, 0]))
        }
        _ = try await session.initialize()
        session.stop()
    }
    func testAcknowledgesBeforeDeliveryAndSuppressesDuplicate() async throws {
        let transport = MemoryTransport()
        let session = TandemSession(transport: transport)
        try await session.open()
        var delivered: [Frame] = []
        session.onNotification = { frame in
            XCTAssertEqual(transport.writes.last, [0x3e, 1, 1, 0, 0, 0, 0, 2, 0x3c])
            delivered.append(frame)
        }
        let battery = Frame(dataType: 0x0c, sequence: 0, payload: [0x25, 0, 80, 0])
        transport.deliver(battery); transport.deliver(battery)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(transport.writes.count, 2)
        session.stop()
    }
    func testRequestCorrelatesTableTypeAndTargetAddress() async throws {
        let transport = MemoryTransport()
        let session = TandemSession(transport: transport, timeout: 0.2, ackTimeout: 0.03)
        try await session.open()
        transport.responder = { frame in
            guard frame.dataType != 1 else { return }
            transport.deliver(.ack(for: frame.sequence))
            transport.deliver(Frame(dataType: 0x0c, sequence: 0, payload: [0x3d, 1, 0] + Array("AA:BB:CC:DD:EE:FF".utf8)))
            transport.deliver(Frame(dataType: 0x0e, sequence: 1, payload: [0x3d, 1, 0] + Array("11:22:33:44:55:66".utf8)))
            transport.deliver(Frame(dataType: 0x0e, sequence: 0, payload: [0x3d, 1, 2] + Array("AA:BB:CC:DD:EE:FF".utf8)))
        }
        let matcher = ReplyMatcher(table: 0x0e, command: 0x3d, type: 1, address: "AA:BB:CC:DD:EE:FF")
        let reply = try await session.request(table: 0x0e, payload: try PeripheralCommands.switchSource("AA:BB:CC:DD:EE:FF"), matching: matcher)
        XCTAssertEqual(try SourceSwitchResult.parse(reply.payload).code, 2)
        session.stop()
    }
    func testMissingAckRetransmitsIdenticalFrameThenFails() async throws {
        let transport = MemoryTransport()
        let session = TandemSession(transport: transport, timeout: 0.2, ackTimeout: 0.01, retries: 2)
        try await session.open()
        do {
            _ = try await session.request(table: 0x0c, payload: [0, 0], matching: .init(table: 0x0c, command: 1, type: 0))
            XCTFail("Missing ACK must fail")
        } catch { XCTAssertTrue(error is TandemError) }
        XCTAssertEqual(transport.writes.count, 3)
        XCTAssertEqual(Set(transport.writes).count, 1)
        XCTAssertFalse(session.isOpen)
    }
    func testDisconnectRejectsPendingRequest() async throws {
        let transport = MemoryTransport()
        let session = TandemSession(transport: transport)
        try await session.open()
        transport.responder = { frame in
            if frame.dataType != 1 { transport.onDisconnect?(nil) }
        }
        do {
            _ = try await session.request(table: 0x0c, payload: [0, 0], matching: .init(table: 0x0c, command: 1, type: 0))
            XCTFail("Disconnect must fail")
        } catch { XCTAssertEqual(error as? TandemError, .disconnected) }
        XCTAssertFalse(session.isOpen)
    }
    func testResponseTimeoutQuarantinesMatcherButAllowsOtherFeature() async throws {
        let transport = MemoryTransport()
        let session = TandemSession(transport: transport, timeout: 0.03, ackTimeout: 0.01)
        try await session.open()
        transport.responder = { frame in
            if frame.dataType != 1 { transport.deliver(.ack(for: frame.sequence)) }
        }
        let battery = ReplyMatcher(table: 0x0c, command: 0x23, type: 0)
        do { _ = try await session.request(table: 0x0c, payload: [0x22, 0], matching: battery); XCTFail() } catch {}
        do { _ = try await session.request(table: 0x0c, payload: [0x22, 0], matching: battery); XCTFail() } catch {}
        XCTAssertEqual(transport.writes.count, 1)
        transport.responder = { frame in
            guard frame.dataType != 1 else { return }
            transport.deliver(.ack(for: frame.sequence))
            transport.deliver(Frame(dataType: 0x0c, sequence: 0, payload: [0x23, 0, 80, 0]))
            transport.deliver(Frame(dataType: 0x0e, sequence: 1, payload: [0x37, 0, 0, 255]))
        }
        let reply = try await session.request(table: 0x0e, payload: [0x36, 0], matching: .init(table: 0x0e, command: 0x37, type: 0))
        XCTAssertEqual(try PeripheralSnapshot.parse(reply.payload).devices.count, 0)
        session.stop()
    }
    func testCancellationClosesSessionAndAllowsFreshHandshake() async throws {
        let transport = MemoryTransport()
        let session = TandemSession(transport: transport)
        try await session.open()
        let task = Task { try await session.request(table: 0x0c, payload: [0, 0], matching: ReplyMatcher(table: 0x0c, command: 1, type: 0)) }
        await Task.yield(); task.cancel()
        do { _ = try await task.value; XCTFail() } catch {}
        XCTAssertFalse(session.isOpen)
        try await session.open()
        transport.responder = { frame in
            guard frame.dataType != 1 else { return }
            transport.deliver(.ack(for: frame.sequence))
            transport.deliver(Frame(dataType: 0x0c, sequence: 0, payload: [1, 0, 3, 0, 0, 0, 0, 0]))
        }
        let generation = try await session.initialize()
        XCTAssertEqual(generation, .v2)
        session.stop()
    }
    func testWriteStallCannotSuspendRequestDeadline() async throws {
        let transport = MemoryTransport()
        transport.writeDelay = 250_000_000
        let session = TandemSession(transport: transport, timeout: 0.03, ackTimeout: 0.01)
        try await session.open()
        let started = ProcessInfo.processInfo.systemUptime
        do { _ = try await session.initialize(); XCTFail() } catch {}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.15)
        XCTAssertFalse(session.isOpen)
    }
    func testOldRequestWriteErrorCannotCloseReopenedSession() async throws {
        let transport = MemoryTransport()
        let session = TandemSession(transport: transport)
        try await session.open()
        let suspended = expectation(description: "Old write suspended")
        var waiting: CheckedContinuation<Void, Error>?
        transport.writeHook = { _ in
            try await withCheckedThrowingContinuation { waiting = $0; suspended.fulfill() }
        }
        let oldRequest = Task { try await session.initialize() }
        await fulfillment(of: [suspended], timeout: 1)
        session.stop()
        transport.writeHook = nil
        try await session.open()
        waiting?.resume(throwing: TandemError.transport("late old write error"))
        _ = try? await oldRequest.value
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(session.isOpen)
        session.stop()
    }
    func testOldAckWriteErrorCannotCloseReopenedSession() async throws {
        let transport = MemoryTransport()
        let session = TandemSession(transport: transport)
        try await session.open()
        let suspended = expectation(description: "Old ACK write suspended")
        var waiting: CheckedContinuation<Void, Error>?
        transport.writeHook = { _ in
            try await withCheckedThrowingContinuation { waiting = $0; suspended.fulfill() }
        }
        transport.deliver(Frame(dataType: 0x0c, sequence: 0, payload: [0x25, 0, 80, 0]))
        await fulfillment(of: [suspended], timeout: 1)
        session.stop(); transport.writeHook = nil
        try await session.open()
        waiting?.resume(throwing: TandemError.transport("late old ACK error"))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(session.isOpen)
        session.stop()
    }
    func testOldConnectErrorCannotCloseReopenedSession() async throws {
        let transport = MemoryTransport()
        let session = TandemSession(transport: transport)
        let suspended = expectation(description: "Old connection suspended")
        var waiting: CheckedContinuation<Void, Error>?
        transport.connectHook = {
            try await withCheckedThrowingContinuation { waiting = $0; suspended.fulfill() }
        }
        let oldOpen = Task { try await session.open() }
        await fulfillment(of: [suspended], timeout: 1)
        session.stop(); transport.connectHook = nil
        try await session.open()
        waiting?.resume(throwing: TandemError.transport("late old connection error"))
        _ = try? await oldOpen.value
        XCTAssertTrue(session.isOpen)
        session.stop()
    }
    func testWriteFailureClosesConnection() async throws {
        let transport = MemoryTransport()
        let session = TandemSession(transport: transport)
        try await session.open(); transport.failWrites = true
        do { _ = try await session.initialize(); XCTFail() } catch {}
        XCTAssertFalse(session.isOpen)
    }
}
