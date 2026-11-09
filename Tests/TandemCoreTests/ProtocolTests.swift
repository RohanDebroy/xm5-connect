import XCTest
@testable import TandemCore

final class ProtocolTests: XCTestCase {
    func testKnownWireVectors() {
        XCTAssertEqual(FrameCodec.encode(Frame(dataType: 0x0c, sequence: 0, payload: [0, 0])),
                       [0x3e, 0x0c, 0, 0, 0, 0, 2, 0, 0, 0x0e, 0x3c])
        XCTAssertEqual(FrameCodec.encode(.ack(for: 0)), [0x3e, 1, 1, 0, 0, 0, 0, 2, 0x3c])
        XCTAssertEqual(FrameCodec.encode(.ack(for: 1)), [0x3e, 1, 0, 0, 0, 0, 0, 1, 0x3c])
    }
    func testFragmentedAndCoalescedEscapedFrames() {
        let wire: [UInt8] = [0x3e, 0x0c, 0, 0, 0, 0, 3, 0x3d, 0x2c, 0x3d, 0x2d, 0x3d, 0x2e, 0xc6, 0x3c]
        var parser = FrameParser()
        var frames: [Frame] = []
        for byte in wire { frames += parser.feed([byte]) }
        XCTAssertEqual(frames, [Frame(dataType: 0x0c, sequence: 0, payload: [0x3c, 0x3d, 0x3e])])
        XCTAssertEqual(FrameCodec.encode(frames[0]), wire)
        XCTAssertEqual(parser.feed(wire + wire).count, 2)
    }
    func testRejectsCorruptionAndResynchronizes() {
        var parser = FrameParser(maxPayload: 16)
        let valid: [UInt8] = [0x3e, 1, 0, 0, 0, 0, 0, 1, 0x3c]
        XCTAssertTrue(parser.feed([0x3e, 1, 0, 0, 0, 0, 0, 2, 0x3c]).isEmpty)
        XCTAssertTrue(parser.feed([0x3e, 1, 0, 0, 0, 0, 0, 1, 7, 0x3c]).isEmpty)
        XCTAssertTrue(parser.feed([0x3e, 0x3d, 0x44, 0x3c]).isEmpty)
        XCTAssertTrue(parser.feed([0x3e] + Array(repeating: 2, count: 100)).isEmpty)
        XCTAssertEqual(parser.feed(valid).count, 1)
        XCTAssertTrue(parser.feed([0x3e, 1, 2, 0, 0, 0, 0, 3, 0x3c]).isEmpty)
    }
    func testGenerationAndCapabilityValidation() throws {
        XCTAssertEqual(try ProtocolGeneration.detect([1, 0, 3, 0, 0, 0, 0, 0]), .v2)
        XCTAssertEqual(try ProtocolGeneration.detect([1, 0, 0, 0]), .v1)
        XCTAssertThrowsError(try ProtocolGeneration.detect([1, 0]))
        var registry = CapabilityRegistry()
        try registry.ingest(table: 0x0e, payload: [7, 0, 2, 0x30, 1, 0x31, 9])
        XCTAssertEqual(registry.version(table: 0x0e, function: 0x30), 1)
        XCTAssertFalse(registry.allows(table: 0x0e, function: 0x31, supportedVersions: [0, 1]))
        XCTAssertFalse(registry.allows(table: 0x0c, function: 0x30, supportedVersions: [1]))
        XCTAssertThrowsError(try registry.ingest(table: 0x0e, payload: [7, 0, 2, 0x30, 1]))
        XCTAssertEqual(registry.version(table: 0x0e, function: 0x30), 1)
    }
    func testBatteryStatusAndUnknownValues() throws {
        let status = try BatteryStatus.parse([0x23, 0, 83, 1])
        XCTAssertEqual(status.level, 83)
        XCTAssertEqual(status.charging, .charging)
        XCTAssertEqual(try BatteryStatus.parse([0x25, 0, 100, 3]).charging, .charged)
        XCTAssertEqual(try BatteryStatus.parse([0x25, 0, 50, 99]).charging, .unknown)
        XCTAssertThrowsError(try BatteryStatus.parse([0x23, 0, 255, 0]))
        XCTAssertThrowsError(try BatteryStatus.parse([0x23, 1, 5, 0]))
        XCTAssertThrowsError(try BatteryStatus.parse([0x23, 0, 50]))
    }
    private var list: [UInt8] {
        var bytes: [UInt8] = [0x37, 0, 2]
        bytes += Array("AA:BB:CC:DD:EE:FF".utf8)
        bytes += [1, 3] + Array("Mac".utf8)
        bytes += Array("11:22:33:44:55:66".utf8)
        bytes += [0, 5] + Array("Phone".utf8) + [0]
        return bytes
    }
    func testDeviceListSeparatesConnectedAndSelected() throws {
        let snapshot = try PeripheralSnapshot.parse(list)
        XCTAssertEqual(snapshot.devices.count, 2)
        XCTAssertEqual(snapshot.connected.map(\.name), ["Mac"])
        XCTAssertEqual(snapshot.selectedAddress, "AA:BB:CC:DD:EE:FF")
        var invalidIndex = list; invalidIndex[invalidIndex.count - 1] = 1
        XCTAssertNil(try PeripheralSnapshot.parse(invalidIndex).selectedAddress)
        invalidIndex[invalidIndex.count - 1] = 255
        XCTAssertNil(try PeripheralSnapshot.parse(invalidIndex).selectedAddress)
        XCTAssertNil(try PeripheralSnapshot.parse(Array(list.dropLast())).selectedAddress)
    }
    func testTruncatedAndInvalidListsAreRejected() {
        for count in 0..<(list.count - 1) {
            XCTAssertThrowsError(try PeripheralSnapshot.parse(Array(list.prefix(count))))
        }
        var badAddress = list; badAddress[3] = 0xff
        XCTAssertThrowsError(try PeripheralSnapshot.parse(badAddress))
        XCTAssertThrowsError(try PeripheralSnapshot.parse(list + [0]))

    }
    func testEmptyFriendlyNameFallsBackToAddress() throws {
        var bytes: [UInt8] = [0x37, 0, 1]
        bytes += Array("AA:BB:CC:DD:EE:FF".utf8)
        bytes += [1, 0, 0]
        let snapshot = try PeripheralSnapshot.parse(bytes)
        XCTAssertEqual(snapshot.connected.first?.name, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(snapshot.selectedAddress, "AA:BB:CC:DD:EE:FF")
    }
    func testDeviceClassListParsesNamesStatusAndSelection() throws {
        var bytes: [UInt8] = [0x37, 2, 2]
        bytes += Array("AA:BB:CC:DD:EE:FF".utf8)
        bytes += [1, 0x24, 0x04, 0x04, 3] + Array("Mac".utf8)
        bytes += Array("11:22:33:44:55:66".utf8)
        bytes += [1, 0x5a, 0x02, 0x0c, 5] + Array("Phone".utf8) + [1]
        let snapshot = try PeripheralSnapshot.parse(bytes)
        XCTAssertEqual(snapshot.connected.map(\.name), ["Mac", "Phone"])
        XCTAssertEqual(snapshot.selectedAddress, "11:22:33:44:55:66")
        for count in 0..<(bytes.count - 1) {
            XCTAssertThrowsError(try PeripheralSnapshot.parse(Array(bytes.prefix(count))))
        }
    }
    func testSourceSwitchEncodingAndResults() throws {
        XCTAssertEqual(try PeripheralCommands.switchSource("aa:bb:cc:dd:ee:ff"),
                       [0x3c, 1] + Array("AA:BB:CC:DD:EE:FF".utf8))
        XCTAssertThrowsError(try PeripheralCommands.switchSource("not-an-address"))
        let reply = try SourceSwitchResult.parse([0x3d, 1, 2] + Array("AA:BB:CC:DD:EE:FF".utf8))
        XCTAssertEqual(reply.address, "AA:BB:CC:DD:EE:FF")
        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.message.contains("call"))
        XCTAssertFalse(try SourceSwitchResult.parse([0x3d, 1, 99] + Array("AA:BB:CC:DD:EE:FF".utf8)).succeeded)
        XCTAssertThrowsError(try SourceSwitchResult.parse([0x3d, 1, 0]))
    }
}
