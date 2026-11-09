import XCTest
@testable import TandemCore

@MainActor
final class ListeningClientTests: XCTestCase {
    private func setup(function: UInt8 = 0x6b, status: [UInt8] = [0x67, 0x17, 1, 1, 0, 0, 20], settle: Bool = true)
    -> (MemoryTransport, SonyDeviceClient, ([UInt8]) -> Void) {
        let transport = MemoryTransport()
        var sequence: UInt8 = 0
        var current = status
        let send: ([UInt8], UInt8) -> Void = { bytes, table in
            transport.deliver(Frame(dataType: table, sequence: sequence, payload: bytes))
            sequence = 1 - sequence
        }
        transport.responder = { frame in
            guard frame.dataType != 1 else { return }
            transport.deliver(.ack(for: frame.sequence))
            let p = frame.payload
            var reply: [UInt8]
            switch (frame.dataType, p) {
            case (0x0c, [0, 0]): reply = [1, 0, 3, 0, 0, 0, 0, 0]
            case (0x0c, [2, 0]): reply = [3, 0, 1, 1, 65]
            case (0x0c, [6, 0]): reply = [7, 0, 2, 0x20, 1, function, 1]
            case (0x0e, [6, 0]): reply = [7, 0, 2, 0x30, 1, 0x31, 1]
            case (0x0c, [0x22, 0]): reply = [0x23, 0, 80, 0]
            case (0x0e, [0x36, 0]):
                reply = [0x37, 0, 1] + Array("AA:BB:CC:DD:EE:FF".utf8)
                reply += [1, 3] + Array("Mac".utf8) + [0]
            case (0x0c, [0x66, 0x17]): reply = current
            default:
                if frame.dataType == 0x0c, p.starts(with: [0x68, 0x17]) {
                    current = p; current[0] = 0x67
                    reply = current; reply[0] = 0x69; reply[2] = settle ? 1 : 0
                } else { XCTFail("Unexpected request \(p)"); return }
            }
            send(reply, frame.dataType)
        }
        let session = TandemSession(transport: transport, timeout: 0.3, ackTimeout: 0.02)
        return (transport, SonyDeviceClient(session: session, descriptorPolicy: .referencePriority), { send($0, 0x0c) })
    }

    func testAmbientLevelUsesFreshSettingsAndWaitsForDeviceLevel() async throws {
        let (transport, client, send) = setup(status: [0x67, 0x17, 1, 1, 1, 1, 15], settle: false)
        try await client.start()
        let before = transport.writes.count
        var completed = false
        let task = Task { let result = try await client.setAmbientLevel(20); completed = true; return result }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(completed)
        send([0x69, 0x17, 1, 1, 1, 1, 20])
        let result = try await task.value
        XCTAssertEqual(result.ambientLevel, 20)
        var parser = FrameParser()
        let commands = transport.writes.dropFirst(before).flatMap { parser.feed($0) }.filter { $0.dataType != 1 }
        XCTAssertEqual(commands.map(\.payload), [[0x66, 0x17], [0x68, 0x17, 1, 1, 1, 1, 20]])
        client.stop()
    }
    func testLevelRejectsDifferentConfirmedLevelAndShowsDeviceValue() async throws {
        let (transport, client, send) = setup(status: [0x67, 0x17, 1, 1, 1, 1, 15])
        try await client.start()
        let original = transport.responder
        transport.responder = { frame in
            if frame.payload.first == 0x68 {
                transport.deliver(.ack(for: frame.sequence))
                send([0x69, 0x17, 1, 1, 1, 1, 12])
            } else { original?(frame) }
        }
        do { _ = try await client.setAmbientLevel(20); XCTFail("Unconfirmed level accepted") } catch {}
        XCTAssertEqual(client.state.listening?.ambientLevel, 12)
        XCTAssertNotNil(client.state.listeningIssue)
        client.stop()
    }
    func testSliderFreshReadRespectsExternalANCChangeWithoutWriting() async throws {
        let (transport, client, send) = setup(status: [0x67, 0x17, 1, 1, 1, 1, 15])
        try await client.start()
        let original = transport.responder
        transport.responder = { frame in
            original?(frame)
            if frame.payload == [0x66, 0x17] { send([0x69, 0x17, 1, 1, 0, 1, 15]) }
        }
        let before = transport.writes.count
        do { _ = try await client.setAmbientLevel(10); XCTFail("External mode change ignored") } catch {}
        var parser = FrameParser()
        let commands = transport.writes.dropFirst(before).flatMap { parser.feed($0) }.filter { $0.dataType != 1 }
        XCTAssertEqual(commands.map(\.payload), [[0x66, 0x17]])
        XCTAssertEqual(client.state.listening?.mode, .noiseCancelling)
        client.stop()
    }
    func testInitialListeningModeLoadsAlongsideBatteryAndSources() async throws {
        let (_, client, _) = setup()
        try await client.start()
        XCTAssertEqual(client.state.listening?.mode, .noiseCancelling)
        XCTAssertEqual(client.state.availableListeningModes, [.noiseCancelling, .ambient, .normal])
        XCTAssertTrue(client.state.canChangeListeningMode)
        XCTAssertEqual(client.state.battery?.level, 80)
        XCTAssertEqual(client.state.peripherals?.connected.map(\.name), ["Mac"])
        client.stop()
        XCTAssertNil(client.state.listening)
        XCTAssertFalse(client.state.canChangeListeningMode)
    }
    func testModeCheckmarkWaitsForSettledDeviceConfirmation() async throws {
        let (_, client, send) = setup(settle: false)
        try await client.start()
        var completed = false
        let change = Task {
            let result = try await client.setListeningMode(.ambient)
            completed = true
            return result
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(completed)
        XCTAssertNil(client.state.listening?.mode)
        send([0x69, 0x17, 1, 1, 1, 0, 20])
        let result = try await change.value
        XCTAssertEqual(result.mode, .ambient)
        XCTAssertEqual(client.state.listening?.mode, .ambient)
        client.stop()
    }
    func testFreshReadOccursBeforeModeWrite() async throws {
        let (transport, client, _) = setup()
        try await client.start()
        let before = transport.writes.count
        let original = transport.responder
        transport.responder = { frame in
            if frame.payload.first == 0x68 { XCTAssertEqual(client.state.listening?.mode, .noiseCancelling) }
            original?(frame)
        }
        let result = try await client.setListeningMode(.ambient)
        XCTAssertEqual(result.mode, .ambient)
        var parser = FrameParser()
        let commands = transport.writes.dropFirst(before).flatMap { parser.feed($0) }.filter { $0.dataType != 1 }
        XCTAssertEqual(commands.map(\.payload), [[0x66, 0x17], [0x68, 0x17, 1, 1, 1, 0, 20]])
        client.stop()
    }
    func testMalformedModeDoesNotHideBatteryOrSourceList() async throws {
        let (_, client, _) = setup(status: [0x67, 0x17])
        try await client.start()
        XCTAssertNil(client.state.listening)
        XCTAssertNotNil(client.state.listeningIssue)
        XCTAssertFalse(client.state.canChangeListeningMode)
        XCTAssertEqual(client.state.battery?.level, 80)
        XCTAssertEqual(client.state.peripherals?.connected.count, 1)
        client.stop()
    }
    func testUnknownModeProfileIsNotQueriedOrWritten() async throws {
        let (transport, client, _) = setup(function: 0x68)
        try await client.start()
        XCTAssertTrue(client.state.availableListeningModes.isEmpty)
        let before = transport.writes.count
        do { _ = try await client.setListeningMode(.ambient); XCTFail() } catch {}
        XCTAssertEqual(transport.writes.count, before)
        client.stop()
    }
    func testNewerNotificationWinsOverOlderSetConfirmation() async throws {
        let (transport, client, send) = setup()
        try await client.start()
        let original = transport.responder
        transport.responder = { frame in
            original?(frame)
            if frame.payload.first == 0x68 { send([0x69, 0x17, 1, 0, 0, 0, 20]) }
        }
        _ = try await client.setListeningMode(.ambient)
        XCTAssertEqual(client.state.listening?.mode, .normal)
        client.stop()
    }
    func testNewerNotificationWinsOverOlderGetReply() async throws {
        let (transport, client, send) = setup()
        try await client.start()
        let original = transport.responder
        transport.responder = { frame in
            original?(frame)
            if frame.payload == [0x66, 0x17] { send([0x69, 0x17, 1, 0, 0, 0, 20]) }
        }
        try await client.refresh()
        XCTAssertEqual(client.state.listening?.mode, .normal)
        client.stop()
    }
    func testModeWritePreservesTheNewestReceivedVoiceAndLevel() async throws {
        let (transport, client, send) = setup()
        try await client.start()
        let original = transport.responder
        transport.responder = { frame in
            original?(frame)
            if frame.payload == [0x66, 0x17] { send([0x69, 0x17, 1, 1, 0, 1, 7]) }
        }
        _ = try await client.setListeningMode(.ambient)
        var parser = FrameParser()
        let commands = transport.writes.flatMap { parser.feed($0) }.filter { $0.dataType == 0x0c && $0.payload.first == 0x68 }
        XCTAssertEqual(commands.last?.payload, [0x68, 0x17, 1, 1, 1, 1, 7])
        client.stop()
    }
    func testMalformedNewerNotificationDoesNotRestoreAnOlderCheckmark() async throws {
        let (transport, client, send) = setup()
        try await client.start()
        let original = transport.responder
        transport.responder = { frame in
            original?(frame)
            if frame.payload == [0x66, 0x17] { send([0x69, 0x17, 1, 1, 9, 0, 20]) }
        }
        try await client.refresh()
        XCTAssertNil(client.state.listening?.mode)
        XCTAssertNotNil(client.state.listeningIssue)
        client.stop()
    }
    func testDifferentSettledModeIsNotReportedAsSuccess() async throws {
        let (_, client, send) = setup(settle: false)
        try await client.start()
        let task = Task { try await client.setListeningMode(.ambient) }
        try await Task.sleep(nanoseconds: 20_000_000)
        send([0x69, 0x17, 1, 1, 0, 0, 20])
        do { _ = try await task.value; XCTFail("A different reported mode must not count as success") } catch {}
        XCTAssertEqual(client.state.listening?.mode, .noiseCancelling)
        XCTAssertNotNil(client.state.listeningIssue)
        client.stop()
    }
    func testHardwareModeNotificationsUpdateTheSelection() async throws {
        let (_, client, send) = setup()
        try await client.start()
        send([0x69, 0x17, 1, 0, 0, 0, 20])
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(client.state.listening?.mode, .normal)
        client.stop()
    }
}
