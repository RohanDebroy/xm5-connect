import Foundation
import TandemCore

/// Keeps service lookup and channel-opening policy testable without Bluetooth
/// hardware. The native adapter supplies actual SDP and RFCOMM operations.
@MainActor
struct RFCOMMConnectionPlan {
    let cachedChannel: () -> UInt8?
    let discover: () async throws -> Void
    let openChannel: (UInt8) async throws -> Void
    var log: (String) -> Void = { _ in }

    func connect() async throws {
        try Task.checkCancellation()
        if let channel = cachedChannel() {
            log("Trying cached Sony RFCOMM channel \(channel)")
            do {
                try await openChannel(channel)
                try Task.checkCancellation()
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A failed cached channel can be stale after a firmware/service
                // change. Refresh SDP once; never guess channel numbers.
                try Task.checkCancellation()
                log("Cached channel failed: \(error.localizedDescription). Refreshing SDP.")
            }
        }
        log("Discovering Sony RFCOMM services")
        try await discover()
        try Task.checkCancellation()
        guard let channel = cachedChannel() else {
            throw TandemError.unsupported("This device does not advertise a Sony Tandem RFCOMM service.")
        }
        log("Trying discovered Sony RFCOMM channel \(channel)")
        try await openChannel(channel)
        try Task.checkCancellation()
    }
}
