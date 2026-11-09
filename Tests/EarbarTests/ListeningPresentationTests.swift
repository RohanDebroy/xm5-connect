import XCTest
import TandemCore
@testable import Earbar

final class ListeningPresentationTests: XCTestCase {
    func testChangingReportKeepsLastConfirmedSelectionAndSlider() throws {
        var presentation = ListeningPresentation()
        presentation.update(try ListeningStatus.parse([0x67, 0x17, 1, 1, 1, 1, 15], profile: .ncAmbient))
        presentation.update(try ListeningStatus.parse([0x69, 0x17, 0, 1, 0, 1, 15], profile: .ncAmbient))
        XCTAssertEqual(presentation.confirmed?.mode, .ambient)
        XCTAssertEqual(presentation.confirmed?.ambientLevel, 15)
        presentation.update(try ListeningStatus.parse([0x69, 0x17, 1, 1, 0, 1, 15], profile: .ncAmbient))
        XCTAssertEqual(presentation.confirmed?.mode, .noiseCancelling)
        XCTAssertEqual(presentation.confirmed?.ambientLevelRange, 1...20)
    }
    func testMissingOrDifferentProfileDoesNotShowAnOldSelection() throws {
        var presentation = ListeningPresentation()
        let ambient = try ListeningStatus.parse([0x67, 0x17, 1, 1, 1, 0, 15], profile: .ncAmbient)
        presentation.update(ambient)
        presentation.update(nil)
        XCTAssertNil(presentation.confirmed)
        presentation.update(ambient)
        presentation.update(try ListeningStatus.parse([0x69, 0x19, 0, 1, 0, 0, 15, 0, 0], profile: .ncAmbientAdaptive))
        XCTAssertNil(presentation.confirmed)
    }
}
