import XCTest
@testable import Earbar

final class ReconnectBudgetTests: XCTestCase {
    func testEachSuccessfulRecoveryStartsAFreshBoundedBudget() {
        var budget = ReconnectBudget()
        for _ in 0..<5 {
            XCTAssertEqual(budget.nextAttempt(), 1)
            XCTAssertEqual(budget.nextAttempt(), 2)
            budget.connectionEstablished()
        }
    }
    func testContinuousFailuresStopAfterThreeAttempts() {
        var budget = ReconnectBudget()
        XCTAssertEqual(budget.nextAttempt(), 1)
        XCTAssertEqual(budget.nextAttempt(), 2)
        XCTAssertEqual(budget.nextAttempt(), 3)
        XCTAssertNil(budget.nextAttempt())
        budget.reset()
        XCTAssertEqual(budget.nextAttempt(), 1)
    }
}
