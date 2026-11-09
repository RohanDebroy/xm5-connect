import XCTest
@testable import TandemCore

@MainActor
final class DeviceClientTests: XCTestCase {
    private func setup(table1: [UInt8] = [7, 0, 1, 0x20, 1], table2: [UInt8] = [7, 0, 2, 0x30, 1, 0x31, 1],
                       generation: [UInt8] = [1, 0, 3, 0, 0, 0, 0, 0],
                       battery: [UInt8] = [0x23, 0, 85, 0],
                       disconnectOnCapacityProbe: Bool = false, switchCode: UInt8 = 2, policy: DescriptorPolicy = .referencePriority) -> (MemoryTransport, SonyDeviceClient) {
        let transport = MemoryTransport()
        var peerSequence: UInt8 = 0
        var switchAccepted = false
        transport.responder = { frame in
            guard frame.dataType != 1 else { return }
            transport.deliver(.ack(for: frame.sequence))
            let p = frame.payload
            var reply: [UInt8]
            switch (frame.dataType, p) {
            case (0x0c, [0, 0]): reply = generation
            case (0x0c, [2, 0]): reply = [3, 0, 1, 1, 65]
            case (0x0c, [6, 0]): reply = table1
            case (0x0e, [6, 0]): reply = table2
            case (0x0e, [0x30, 0]):
                if disconnectOnCapacityProbe { transport.onDisconnect?(TandemError.disconnected); return }
                reply = [0x31, 0, 2, 0, 0]
            case (0x0e, [0x30, 2]): reply = [0x31, 2, 2, 0, 0]
            case (0x0e, [0x36, 2]):
                reply = [0x37, 2, 1] + Array("AA:BB:CC:DD:EE:FF".utf8)
                reply += [1, 0x24, 0x04, 0x04, 3] + Array("Mac".utf8)
                if switchCode == 0 {
                    reply[2] = 2
                    reply += Array("11:22:33:44:55:66".utf8)
                    reply += [1, 0x5a, 0x02, 0x0c, 5] + Array("Phone".utf8)
                }
                reply += [switchAccepted ? 1 : 0]
            case (0x0c, [0x22, 0]): reply = battery
            case (0x0e, [0x36, 0]):
                reply = [0x37, 0, 1] + Array("AA:BB:CC:DD:EE:FF".utf8)
                reply += [1, 3] + Array("Mac".utf8)
                if switchCode == 0 {
                    reply[2] = 2
                    reply += Array("11:22:33:44:55:66".utf8)
                    reply += [1, 5] + Array("Phone".utf8)
                }
                reply += [switchAccepted ? 1 : 0]
            default:
                if p.starts(with: [0x3c, 1]) {
                    switchAccepted = switchCode == 0
                    reply = [0x3d, 1, switchCode] + Array(p.dropFirst(2))
                }
                else { XCTFail("Unexpected command \(p)"); return }
            }
            transport.deliver(Frame(dataType: frame.dataType, sequence: peerSequence, payload: reply))
            peerSequence = 1 - peerSequence
        }
        let session = TandemSession(transport: transport, timeout: 0.1, ackTimeout: 0.01)
        return (transport, SonyDeviceClient(session: session, descriptorPolicy: policy))
    }
    func testNegotiatedFeaturesPopulateIndependentState() async throws {
        let (transport, client) = setup()
        try await client.start()
        XCTAssertEqual(client.state.battery?.level, 85)
        XCTAssertEqual(client.state.peripherals?.connected.map(\.name), ["Mac"])
        XCTAssertNil(client.state.sourceCapacity)
        XCTAssertTrue(client.state.canSwitch)
        client.stop()
        XCTAssertNil(client.state.battery)
        XCTAssertNil(client.state.peripherals)
        XCTAssertFalse(transport.isOpen)
    }
    func testMalformedBatteryDoesNotHideSources() async throws {
        let (_, client) = setup(battery: [0x23, 0, 255, 0])
        try await client.start()
        XCTAssertNil(client.state.battery)
        XCTAssertNotNil(client.state.batteryIssue)
        XCTAssertEqual(client.state.peripherals?.connected.count, 1)
        client.stop()
    }
    func testUnadvertisedFeaturesAreNeverQueried() async throws {
        let (transport, client) = setup(table1: [7, 0, 0], table2: [7, 0, 0])
        try await client.start()
        XCTAssertNil(client.state.battery)
        XCTAssertFalse(client.state.canSwitch)
        var parser = FrameParser()
        let sent = transport.writes.flatMap { parser.feed($0) }.filter { $0.dataType != 1 }
        XCTAssertFalse(sent.contains { $0.payload == [0x22, 0] || $0.payload == [0x36, 0] })
        client.stop()
    }
    func testVersionedPolicyRejectsUnknownDescriptorVersions() async throws {
        let (_, client) = setup(table2: [7, 0, 2, 0x30, 1, 0x31, 9], policy: .capabilityVersions([1]))
        try await client.start()
        XCTAssertFalse(client.state.canSwitch)
        do { _ = try await client.switchSource("AA:BB:CC:DD:EE:FF"); XCTFail() } catch {}
        client.stop()
    }
    func testSwitchFailurePreservesReportedSelectionAndRejectsUnknownTarget() async throws {
        let (transport, client) = setup()
        try await client.start()
        let before = transport.writes.count
        do { _ = try await client.switchSource("11:22:33:44:55:66"); XCTFail() } catch {}
        XCTAssertEqual(transport.writes.count, before)
        let result = try await client.switchSource("AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(result.code, 2)
        XCTAssertEqual(client.state.peripherals?.selectedAddress, "AA:BB:CC:DD:EE:FF")
        client.stop()
    }
    func testSuccessfulSwitchReadsNewDeviceReportedSelection() async throws {
        let (_, client) = setup(switchCode: 0)
        try await client.start()
        XCTAssertEqual(client.state.peripherals?.selectedAddress, "AA:BB:CC:DD:EE:FF")
        let result = try await client.switchSource("11:22:33:44:55:66")
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(client.state.peripherals?.selectedAddress, "11:22:33:44:55:66")
        XCTAssertEqual(client.state.peripherals?.connected.map(\.name), ["Mac", "Phone"])
        client.stop()
    }
    func testMalformedTable1SupportDoesNotHidePeripheralFeatures() async throws {
        let (_, client) = setup(table1: [7, 0, 1])
        try await client.start()
        XCTAssertNotNil(client.state.batteryIssue)
        XCTAssertEqual(client.state.peripherals?.connected.map(\.name), ["Mac"])
        XCTAssertTrue(client.state.canSwitch)
        client.stop()
    }
    func testAdvertisedDeviceClassFormatRequestsItsOwnListType() async throws {
        let (_, client) = setup(table2: [7, 0, 2, 0x32, 1, 0x31, 1])
        try await client.start()
        XCTAssertEqual(client.state.peripherals?.connected.map(\.name), ["Mac"])
        XCTAssertTrue(client.state.canSwitch)
        client.stop()
    }
    func testClassicLEDeviceClassFunctionUsesDocumentedType2Format() async throws {
        let (_, client) = setup(table2: [7, 0, 2, 0x33, 1, 0x31, 1])
        try await client.start()
        XCTAssertEqual(client.state.peripherals?.connected.map(\.name), ["Mac"])
        client.stop()
    }
    func testDeviceClassSourceSwitchRefreshUsesTheNegotiatedFormat() async throws {
        let (_, client) = setup(table2: [7, 0, 2, 0x32, 1, 0x31, 1], switchCode: 0)
        try await client.start()
        let result = try await client.switchSource("11:22:33:44:55:66")
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(client.state.peripherals?.selectedAddress, "11:22:33:44:55:66")
        XCTAssertEqual(client.state.peripherals?.connected.map(\.name), ["Mac", "Phone"])
        client.stop()
    }
    func testDeviceClassNotificationsUpdateTheConnectedSources() async throws {
        let (transport, client) = setup(table2: [7, 0, 2, 0x32, 1, 0x31, 1])
        try await client.start()
        var notification: [UInt8] = [0x39, 2, 1]
        notification += Array("11:22:33:44:55:66".utf8)
        notification += [1, 0x5a, 0x02, 0x0c, 5] + Array("Phone".utf8) + [0]
        transport.deliver(Frame(dataType: 0x0e, sequence: 0, payload: notification))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(client.state.peripherals?.connected.map(\.name), ["Phone"])
        XCTAssertEqual(client.state.peripherals?.selectedAddress, "11:22:33:44:55:66")
        client.stop()
    }
    func testListLoadingDoesNotDependOnAnOptionalCapacityProbe() async throws {
        let (transport, client) = setup(disconnectOnCapacityProbe: true)
        try await client.start()
        XCTAssertEqual(client.state.peripherals?.connected.map(\.name), ["Mac"])
        var parser = FrameParser()
        let sent = transport.writes.flatMap { parser.feed($0) }.filter { $0.dataType != 1 }
        XCTAssertFalse(sent.contains { $0.dataType == 0x0e && $0.payload.first == 0x30 })
        client.stop()
    }
    func testBatteryLoadsBeforeOptionalTable2Negotiation() async throws {
        let (transport, client) = setup()
        try await client.start()
        var parser = FrameParser()
        let sent = transport.writes.flatMap { parser.feed($0) }.filter { $0.dataType != 1 }
        let battery = try XCTUnwrap(sent.firstIndex { $0.dataType == 0x0c && $0.payload == [0x22, 0] })
        let peripherals = try XCTUnwrap(sent.firstIndex { $0.dataType == 0x0e && $0.payload == [6, 0] })
        XCTAssertLessThan(battery, peripherals)
        client.stop()
    }
    func testV1StopsBeforeV2Negotiation() async throws {
        let (transport, client) = setup(generation: [1, 0, 0, 0])
        do { try await client.start(); XCTFail() } catch {}
        var parser = FrameParser()
        let commands = transport.writes.flatMap { parser.feed($0) }.filter { $0.dataType != 1 }
        XCTAssertEqual(commands.map(\.payload), [[0, 0]])
        client.stop()
    }
}
