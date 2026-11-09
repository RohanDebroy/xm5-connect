import Foundation
@preconcurrency import IOBluetooth
import TandemCore

@MainActor
final class RFCOMMTransport: NSObject, TandemTransport, IOBluetoothRFCOMMChannelDelegate {
    var onBytes: (([UInt8]) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    private let device: IOBluetoothDevice
    private let log: (String) -> Void
    private let writer = DispatchQueue(label: "Earbar.RFCOMM.writer")
    private var channel: IOBluetoothRFCOMMChannel?
    private var query: SDPQuery?
    private var opening: CheckedContinuation<Void, Error>?
    private var timer: Task<Void, Never>?
    private var connectionID = UUID()

    init(device: IOBluetoothDevice, log: @escaping (String) -> Void = { _ in }) {
        self.device = device; self.log = log
    }

    func connect() async throws {
        disconnect()
        let attempt = connectionID
        log("RFCOMM connect: paired=\(device.isPaired()), connected=\(device.isConnected()), cached channel=\(String(describing: SonyServices.channelID(for: device)))")
        let plan = RFCOMMConnectionPlan(cachedChannel: { SonyServices.channelID(for: self.device) }, discover: {
            guard self.connectionID == attempt else { throw CancellationError() }
            let query = SDPQuery(device: self.device, log: self.log)
            self.query = query
            try await query.run()
            guard self.connectionID == attempt else { throw CancellationError() }
        }, openChannel: { channelID in
            guard self.connectionID == attempt else { throw CancellationError() }
            try await self.openChannel(channelID, attempt: attempt)
        }, log: log)
        try await plan.connect()
    }

    private func openChannel(_ channelID: BluetoothRFCOMMChannelID, attempt: UUID) async throws {
        closeChannel()
        do {
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    opening = continuation
                    let result = device.openRFCOMMChannelAsync(&channel, withChannelID: channelID, delegate: self)
                    if result != kIOReturnSuccess {
                        finishOpening(.failure(SDPQuery.error(result)))
                    } else {
                        timer = Task { [weak self] in
                            do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
                            guard let self, self.connectionID == attempt else { return }
                            self.finishOpening(.failure(TandemError.timedOut("RFCOMM connection")))
                            self.closeChannel()
                        }
                    }
                }
            }, onCancel: { [weak self] in
                Task { @MainActor in
                    guard let self, self.connectionID == attempt else { return }
                    self.disconnect()
                }
            })
        } catch {
            if connectionID == attempt { closeChannel() }
            throw error
        }
    }

    func disconnect() {
        connectionID = UUID()
        query?.cancel()
        finishOpening(.failure(TandemError.disconnected))
        closeChannel()
    }

    private func closeChannel() {
        let old = channel; channel = nil
        old?.setDelegate(nil)
        old?.close() // Close only this RFCOMM channel; never close the audio link.
    }

    func write(_ bytes: [UInt8]) async throws {
        guard let channel, channel.isOpen() else { throw TandemError.disconnected }
        let attempt = connectionID
        let mtu = max(1, min(Int(channel.getMTU()), Int(UInt16.max)))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.async {
                var offset = 0
                while offset < bytes.count {
                    var chunk = Array(bytes[offset..<min(offset + mtu, bytes.count)])
                    let result = chunk.withUnsafeMutableBytes { pointer in
                        channel.writeSync(pointer.baseAddress, length: UInt16(pointer.count))
                    }
                    if result != kIOReturnSuccess {
                        continuation.resume(throwing: SDPQuery.error(result)); return
                    }
                    offset += chunk.count
                }
                continuation.resume()
            }
        }
        guard connectionID == attempt else { throw TandemError.disconnected }
    }

    nonisolated func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        Task { @MainActor in
            guard rfcommChannel == self.channel else { return }
            self.log(String(format: "RFCOMM open completed: 0x%08X", UInt32(bitPattern: error)))
            self.finishOpening(error == kIOReturnSuccess ? .success(()) : .failure(SDPQuery.error(error)))
        }
    }
    nonisolated func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        Task { @MainActor in
            guard rfcommChannel == self.channel else { return }
            self.onBytes?(bytes)
        }
    }
    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        Task { @MainActor in
            guard rfcommChannel == self.channel else { return }
            self.channel = nil
            self.finishOpening(.failure(TandemError.disconnected))
            self.onDisconnect?(nil)
        }
    }
    private func finishOpening(_ result: Result<Void, Error>) {
        timer?.cancel(); timer = nil
        let waiting = opening; opening = nil
        waiting?.resume(with: result)
    }
}
