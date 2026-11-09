import Foundation
import TandemCore

/// Candidates have already been restricted to alive Bluetooth output devices.
struct AudioOutputEndpoint {
    let id: UInt32
    let uid: String?
    let name: String?
}

enum AudioRoutingPolicy {
    static func outputID(for headphones: HeadphoneCandidate, outputs: [AudioOutputEndpoint]) -> UInt32? {
        guard let address = AutoConnectionPolicy.addressPrefix(headphones.id) else { return nil }
        let matches = outputs.filter { AutoConnectionPolicy.addressPrefix($0.uid ?? "") == address }
        if matches.count == 1 { return matches[0].id }
        guard matches.isEmpty, !headphones.name.isEmpty else { return nil }
        // A different address is positive evidence of a different device, even
        // when names collide. Only opaque UIDs may fall back to a unique name.
        let names = outputs.filter {
            AutoConnectionPolicy.addressPrefix($0.uid ?? "") == nil &&
            $0.name?.caseInsensitiveCompare(headphones.name) == .orderedSame
        }
        return names.count == 1 ? names[0].id : nil
    }
}

@MainActor
enum SourceSwitchCoordinator {
    static func perform(sourceAddress: String, localAddress: String?,
                        request: () async throws -> SourceSwitchResult,
                        routeLocalOutput: () async throws -> Void) async throws -> String {
        let result = try await request()
        try Task.checkCancellation()
        guard result.succeeded else { return result.message }
        guard let localAddress,
              let local = AutoConnectionPolicy.addressPrefix(localAddress),
              AutoConnectionPolicy.addressPrefix(sourceAddress) == local else { return result.message }
        do {
            try await routeLocalOutput()
            return "Headphone switch accepted. macOS output set to the headphones."
        } catch is CancellationError { throw CancellationError() }
        catch { return "Headphone switch accepted, but macOS output could not be changed: \(error.localizedDescription)" }
    }
}
