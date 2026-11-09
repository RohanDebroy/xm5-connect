import XCTest
@testable import TandemCore

final class ListeningModeTests: XCTestCase {
    func testNegotiatesDocumentedProfilesByFunctionRatherThanName() throws {
        var caps = CapabilityRegistry()
        try caps.ingest(table: 0x0c, payload: [7, 0, 2, 0x67, 1, 0x6b, 1])
        XCTAssertEqual(ListeningProfile.negotiate(caps, policy: .referencePriority), .ncAmbient)
        try caps.ingest(table: 0x0c, payload: [7, 0, 1, 0x6d, 1])
        XCTAssertEqual(ListeningProfile.negotiate(caps, policy: .referencePriority), .ncAmbientAdaptive)
        try caps.ingest(table: 0x0c, payload: [7, 0, 1, 0x68, 1])
        XCTAssertNil(ListeningProfile.negotiate(caps, policy: .referencePriority))
        try caps.ingest(table: 0x0c, payload: [7, 0, 1, 0x6b, 9])
        XCTAssertNil(ListeningProfile.negotiate(caps, policy: .capabilityVersions([1])))
    }
    func testReadsANCTransparencyAndNormal() throws {
        XCTAssertEqual(try ListeningStatus.parse([0x67, 0x17, 1, 1, 0, 0, 20], profile: .ncAmbient).mode, .noiseCancelling)
        XCTAssertEqual(try ListeningStatus.parse([0x69, 0x17, 1, 1, 1, 0, 20], profile: .ncAmbient).mode, .ambient)
        XCTAssertEqual(try ListeningStatus.parse([0x67, 0x17, 1, 0, 1, 0, 20], profile: .ncAmbient).mode, .normal)
        XCTAssertNil(try ListeningStatus.parse([0x69, 0x17, 0, 1, 1, 0, 20], profile: .ncAmbient).mode)
    }
    func testSwitchPreservesVoiceAndLevelFields() throws {
        let current = try ListeningStatus.parse([0x67, 0x17, 1, 1, 0, 1, 12], profile: .ncAmbient)
        XCTAssertEqual(try current.command(for: .ambient), [0x68, 0x17, 1, 1, 1, 1, 12])
        XCTAssertEqual(try current.command(for: .normal), [0x68, 0x17, 1, 0, 0, 1, 12])
        XCTAssertEqual(try current.command(for: .noiseCancelling), [0x68, 0x17, 1, 1, 0, 1, 12])
    }
    func testSwitchPreservesAdaptivePayloadTail() throws {
        let current = try ListeningStatus.parse([0x67, 0x19, 1, 1, 1, 1, 8, 1, 2], profile: .ncAmbientAdaptive)
        XCTAssertEqual(try current.command(for: .noiseCancelling), [0x68, 0x19, 1, 1, 0, 1, 8, 1, 2])
    }
    func testZeroAmbientLevelUsesReferenceMinimumWhenEnablingAmbient() throws {
        let current = try ListeningStatus.parse([0x67, 0x17, 1, 0, 0, 0, 0], profile: .ncAmbient)
        XCTAssertEqual(try current.command(for: .ambient), [0x68, 0x17, 1, 1, 1, 0, 1])
    }
    func testAmbientOnlyProfilesDoNotOfferANC() throws {
        let seamless = try ListeningStatus.parse([0x67, 0x22, 1, 0, 1, 10], profile: .ambientLevel)
        XCTAssertEqual(seamless.mode, .normal)
        XCTAssertEqual(try seamless.command(for: .ambient), [0x68, 0x22, 1, 1, 1, 10])
        XCTAssertThrowsError(try seamless.command(for: .noiseCancelling))
        let onOff = try ListeningStatus.parse([0x67, 0x21, 1, 1, 0, 1], profile: .ambientOnOff)
        XCTAssertEqual(onOff.mode, .ambient)
        XCTAssertEqual(try onOff.command(for: .normal), [0x68, 0x21, 1, 0, 0, 1])
    }
    func testRejectsMalformedAndChangingStateBeforeWriting() throws {
        let valid: [UInt8] = [0x67, 0x17, 1, 1, 0, 0, 20]
        for length in 0..<valid.count {
            XCTAssertThrowsError(try ListeningStatus.parse(Array(valid.prefix(length)), profile: .ncAmbient))
        }
        XCTAssertThrowsError(try ListeningStatus.parse(valid + [0], profile: .ncAmbient))
        XCTAssertThrowsError(try ListeningStatus.parse([0x67, 0x17, 1, 1, 9, 0, 20], profile: .ncAmbient))
        XCTAssertThrowsError(try ListeningStatus.parse(valid, profile: .ncAmbientAdaptive))
        let changing = try ListeningStatus.parse([0x69, 0x17, 0, 1, 1, 0, 20], profile: .ncAmbient)
        XCTAssertThrowsError(try changing.command(for: .ambient))
    }
    func testAmbientSliderCommandPreservesVoiceAndUsesExactDeviceLevel() throws {
        let current = try ListeningStatus.parse([0x67, 0x17, 1, 1, 1, 1, 15], profile: .ncAmbient)
        XCTAssertEqual(current.ambientLevel, 15)
        for level in [1, 20] {
            XCTAssertEqual(try current.command(ambientLevel: level), [0x68, 0x17, 1, 1, 1, 1, UInt8(level)])
        }
        for level in [-1, 0, 21, 256] { XCTAssertThrowsError(try current.command(ambientLevel: level)) }
    }
    func testMalformedAmbientLevelCannotDriveSlider() throws {
        XCTAssertThrowsError(try ListeningStatus.parse([0x67, 0x17, 1, 1, 1, 1, 255], profile: .ncAmbient))
        XCTAssertEqual(try ListeningStatus.parse([0x67, 0x17, 1, 0, 0, 0, 0], profile: .ncAmbient).ambientLevel, 0)
    }
    func testSliderCannotActivateAmbientAfterExternalModeChange() throws {
        let anc = try ListeningStatus.parse([0x67, 0x17, 1, 1, 0, 1, 15], profile: .ncAmbient)
        XCTAssertThrowsError(try anc.command(ambientLevel: 10))
        let unknownRange = try ListeningStatus.parse([0x67, 0x22, 1, 1, 0, 10], profile: .ambientLevel)
        XCTAssertNil(unknownRange.ambientLevelRange)
        XCTAssertThrowsError(try unknownRange.command(ambientLevel: 10))
    }
    func testSettledReplyMatcherIgnoresIntermediateChangeNotifications() {
        let match = ReplyMatcher(table: 0x0c, command: 0x69, type: 0x17, requiresSettledChange: true)
        XCTAssertFalse(match.matches(Frame(dataType: 0x0c, sequence: 0, payload: [0x69, 0x17, 0, 1, 1, 0, 20])))
        XCTAssertTrue(match.matches(Frame(dataType: 0x0c, sequence: 1, payload: [0x69, 0x17, 1, 1, 1, 0, 20])))
    }
}
