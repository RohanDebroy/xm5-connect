import XCTest
@testable import Earbar

final class AutoConnectionTests: XCTestCase {
    private let macHeadphones = HeadphoneCandidate(id: "AA-BB-CC-DD-EE-FF", name: "Headphones A", isConnected: true)
    private let otherHeadphones = HeadphoneCandidate(id: "11-22-33-44-55-66", name: "Headphones B", isConnected: true)

    func testActiveMacAudioOutputWinsOverPreviouslySavedHeadphones() {
        let output = AudioOutputIdentity(uid: "11:22:33:44:55:66:output", name: "Headphones B")
        XCTAssertEqual(AutoConnectionPolicy.targetID(candidates: [macHeadphones, otherHeadphones], savedID: macHeadphones.id, output: output), otherHeadphones.id)
    }
    func testOnlyConnectedHeadphonesAreEligible() {
        let offline = HeadphoneCandidate(id: "11-22-33-44-55-66", name: "Headphones B", isConnected: false)
        let output = AudioOutputIdentity(uid: "11:22:33:44:55:66:output", name: "Headphones B")
        XCTAssertEqual(AutoConnectionPolicy.targetID(candidates: [macHeadphones, offline], savedID: offline.id, output: output), macHeadphones.id)
        XCTAssertNil(AutoConnectionPolicy.targetID(candidates: [offline], savedID: offline.id, output: output))
    }
    func testSavedConnectedHeadphonesAreUsedWhenOutputDoesNotIdentifyOne() {
        XCTAssertEqual(AutoConnectionPolicy.targetID(candidates: [macHeadphones, otherHeadphones], savedID: macHeadphones.id, output: nil), macHeadphones.id)
    }
    func testAmbiguousDevicesAreNotChosenArbitrarily() {
        XCTAssertNil(AutoConnectionPolicy.targetID(candidates: [macHeadphones, otherHeadphones], savedID: nil, output: nil))
        let duplicate = HeadphoneCandidate(id: "11-22-33-44-55-66", name: macHeadphones.name, isConnected: true)
        XCTAssertNil(AutoConnectionPolicy.targetID(candidates: [macHeadphones, duplicate], savedID: nil,
                                                   output: AudioOutputIdentity(uid: "no-address", name: macHeadphones.name)))
    }
    func testUniqueAudioOutputNameIsFallbackWhenMacDoesNotExposeAddressUID() {
        XCTAssertEqual(AutoConnectionPolicy.targetID(candidates: [macHeadphones, otherHeadphones], savedID: nil,
                                                    output: AudioOutputIdentity(uid: "opaque-uid", name: "headphones b")), otherHeadphones.id)
    }
    func testUidAddressMatchIsPreferredOverConflictingFriendlyName() {
        let output = AudioOutputIdentity(uid: "AA-BB-CC-DD-EE-FF:output", name: "Headphones B")
        XCTAssertEqual(AutoConnectionPolicy.targetID(candidates: [macHeadphones, otherHeadphones], savedID: nil, output: output), macHeadphones.id)
    }
}
