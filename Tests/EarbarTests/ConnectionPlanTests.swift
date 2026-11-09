import XCTest
@testable import Earbar
import TandemCore

@MainActor
final class ConnectionPlanTests: XCTestCase {
    func testKnownSonyChannelConnectsEvenWhenFreshDiscoveryWouldTimeOut() async throws {
        var opened: [UInt8] = []
        let plan = RFCOMMConnectionPlan(cachedChannel: { 7 }, discover: {
            XCTFail("A known channel must be tried before waiting for discovery")
            throw TandemError.timedOut("Bluetooth service discovery")
        }, openChannel: { opened.append($0) })
        try await plan.connect()
        XCTAssertEqual(opened, [7])
    }

    func testStaleChannelTriggersDiscoveryAndRetriesNewChannelOnce() async throws {
        var cached: UInt8 = 7
        var opened: [UInt8] = []
        var discoveries = 0
        let plan = RFCOMMConnectionPlan(cachedChannel: { cached }, discover: {
            discoveries += 1; cached = 9
        }, openChannel: { channel in
            opened.append(channel)
            if channel == 7 { throw TandemError.transport("stale channel") }
        })
        try await plan.connect()
        XCTAssertEqual(opened, [7, 9])
        XCTAssertEqual(discoveries, 1)
    }

    func testNoCachedServiceDiscoversBeforeOpening() async throws {
        var cached: UInt8?
        var events: [String] = []
        let plan = RFCOMMConnectionPlan(cachedChannel: { cached }, discover: {
            events.append("discover"); cached = 9
        }, openChannel: { channel in events.append("open \(channel)") })
        try await plan.connect()
        XCTAssertEqual(events, ["discover", "open 9"])
    }

    func testMissingServiceDoesNotGuessOrOpenAnArbitraryChannel() async throws {
        let plan = RFCOMMConnectionPlan(cachedChannel: { nil }, discover: {}, openChannel: { _ in XCTFail() })
        do { try await plan.connect(); XCTFail("Missing service must fail") }
        catch { guard case TandemError.unsupported = error else { return XCTFail("Unexpected error \(error)") } }
    }

    func testCancellationDoesNotStartFallbackDiscovery() async throws {
        var discoveries = 0
        let plan = RFCOMMConnectionPlan(cachedChannel: { 7 }, discover: { discoveries += 1 }, openChannel: { _ in
            throw CancellationError()
        })
        do { try await plan.connect(); XCTFail() } catch is CancellationError {} catch { XCTFail("Wrong error") }
        XCTAssertEqual(discoveries, 0)
    }

    func testFailedFreshChannelIsNotRetriedForever() async throws {
        var opened = 0
        var discoveries = 0
        let plan = RFCOMMConnectionPlan(cachedChannel: { 7 }, discover: { discoveries += 1 }, openChannel: { _ in
            opened += 1; throw TandemError.transport("open failed")
        })
        do { try await plan.connect(); XCTFail() } catch {}
        XCTAssertEqual(opened, 2)
        XCTAssertEqual(discoveries, 1)
    }
}
