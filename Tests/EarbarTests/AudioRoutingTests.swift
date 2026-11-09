import XCTest
import TandemCore
@testable import Earbar

@MainActor
final class AudioRoutingTests: XCTestCase {
    private let local = "AA:BB:CC:DD:EE:FF"
    private let phone = "11:22:33:44:55:66"

    func testLocalSwitchRoutesOnlyAfterHeadphonesAccept() async throws {
        var steps: [String] = []
        let message = try await SourceSwitchCoordinator.perform(sourceAddress: local, localAddress: "aa-bb-cc-dd-ee-ff", request: {
            steps.append("headphones")
            return try self.result(address: self.local, code: 0)
        }, routeLocalOutput: { steps.append("macOS") })
        XCTAssertEqual(steps, ["headphones", "macOS"])
        XCTAssertTrue(message.contains("macOS"))
    }
    func testRemoteOrUnknownSourceDoesNotChangeMacOutput() async throws {
        for localAddress in [local, nil] {
            var routed = false
            _ = try await SourceSwitchCoordinator.perform(sourceAddress: phone, localAddress: localAddress, request: {
                try self.result(address: self.phone, code: 0)
            }, routeLocalOutput: { routed = true })
            XCTAssertFalse(routed)
        }
    }
    func testRejectedSwitchDoesNotChangeMacOutput() async throws {
        var routed = false
        let message = try await SourceSwitchCoordinator.perform(sourceAddress: local, localAddress: local, request: {
            try self.result(address: self.local, code: 2)
        }, routeLocalOutput: { routed = true })
        XCTAssertFalse(routed)
        XCTAssertTrue(message.contains("call"))
    }
    func testRoutingFailureReportsPartialSuccess() async throws {
        let message = try await SourceSwitchCoordinator.perform(sourceAddress: local, localAddress: local, request: {
            try self.result(address: self.local, code: 0)
        }, routeLocalOutput: { throw TandemError.transport("Output unavailable") })
        XCTAssertTrue(message.contains("accepted"))
        XCTAssertTrue(message.contains("Output unavailable"))
    }
    func testCancelledActionCannotChangeMacOutput() async throws {
        var routed = false
        let task = Task {
            try await SourceSwitchCoordinator.perform(sourceAddress: local, localAddress: local, request: {
                withUnsafeCurrentTask { $0?.cancel() }
                return try self.result(address: self.local, code: 0)
            }, routeLocalOutput: { routed = true })
        }
        do { _ = try await task.value; XCTFail("Cancelled action accepted") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(routed)
    }
    func testOutputMatchingUsesAddressAndRejectsAmbiguousNames() {
        let headset = HeadphoneCandidate(id: "AA-BB-CC-DD-EE-FF", name: "Headphones", isConnected: true)
        let addressMatch = AudioOutputEndpoint(id: 7, uid: "AA:BB:CC:DD:EE:FF:output", name: "Other name")
        let wrongAddress = AudioOutputEndpoint(id: 8, uid: "11:22:33:44:55:66:output", name: "Headphones")
        XCTAssertEqual(AudioRoutingPolicy.outputID(for: headset, outputs: [wrongAddress, addressMatch]), 7)
        XCTAssertNil(AudioRoutingPolicy.outputID(for: headset, outputs: [wrongAddress]))
        let fallback = AudioOutputEndpoint(id: 9, uid: "opaque", name: "Headphones")
        XCTAssertEqual(AudioRoutingPolicy.outputID(for: headset, outputs: [fallback]), 9)
        XCTAssertNil(AudioRoutingPolicy.outputID(for: headset, outputs: [fallback, AudioOutputEndpoint(id: 10, uid: "opaque2", name: "Headphones")]))
    }
    private func result(address: String, code: UInt8) throws -> SourceSwitchResult {
        try SourceSwitchResult.parse([0x3d, 1, code] + Array(address.utf8))
    }
}
