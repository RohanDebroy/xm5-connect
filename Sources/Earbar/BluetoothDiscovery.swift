import Foundation
import Combine
@preconcurrency import IOBluetooth
import TandemCore

enum SonyServices {
    static let uuids: [IOBluetoothSDPUUID] = [
        "956C7B26-D49A-4BA8-B03F-B17D393CB6E2",
        "96CC203E-5068-46AD-B32D-E316F5E069BA"
    ].map { value in
        var bytes = UUID(uuidString: value)!.uuid
        return withUnsafeBytes(of: &bytes) { IOBluetoothSDPUUID(bytes: $0.baseAddress, length: 16) }
    }
    static func channelID(for device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        for uuid in uuids {
            var channel: BluetoothRFCOMMChannelID = 0
            if let record = device.getServiceRecord(for: uuid), record.getRFCOMMChannelID(&channel) == kIOReturnSuccess {
                return channel
            }
        }
        return nil
    }
}

/// A query object is used once so a late delegate callback cannot complete a
/// subsequent SDP query. Keep the delegate alive for the duration of discovery.
@MainActor
final class SDPQuery: NSObject {
    private let device: IOBluetoothDevice
    private let log: (String) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var timer: Task<Void, Never>?
    init(device: IOBluetoothDevice, log: @escaping (String) -> Void = { _ in }) {
        self.device = device; self.log = log
    }

    func run() async throws {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                log("SDP query started; existing service records=\(device.services?.count ?? 0)")
                let result = device.performSDPQuery(self, uuids: SonyServices.uuids)
                log(String(format: "SDP start returned 0x%08X", UInt32(bitPattern: result)))
                if result != kIOReturnSuccess { finish(.failure(Self.error(result))) }
                else {
                    timer = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                        self?.log("SDP callback did not arrive before the 8-second deadline")
                        self?.finish(.failure(TandemError.transport("Bluetooth service discovery timed out before macOS returned a Sony service record. The device may still be paired. Connect it in macOS Bluetooth settings and retry; Copy Diagnostics includes the failing stage.")))
                    }
                }
            }
        }, onCancel: { [weak self] in Task { @MainActor in self?.cancel() } })
    }
    func cancel() { finish(.failure(CancellationError())) }
    @objc nonisolated func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        Task { @MainActor in
            guard device == self.device else { return }
            log(String(format: "SDP callback returned 0x%08X", UInt32(bitPattern: status)))
            finish(status == kIOReturnSuccess ? .success(()) : .failure(Self.error(status)))
        }
    }
    private func finish(_ result: Result<Void, Error>) {
        timer?.cancel(); timer = nil
        let waiting = continuation; continuation = nil
        waiting?.resume(with: result)
    }
    nonisolated static func error(_ status: IOReturn) -> TandemError {
        .transport(String(format: "Bluetooth error 0x%08X. Check that Bluetooth is on, the device is paired, and Earbar has Bluetooth access in System Settings.", UInt32(bitPattern: status)))
    }
}

struct PairedHeadphone: Identifiable {
    let device: IOBluetoothDevice
    var id: String { device.addressString ?? "" }
    var name: String { device.name ?? "Sony audio device" }
}

@MainActor
final class DeviceCatalog: ObservableObject {
    @Published private(set) var devices: [PairedHeadphone] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var message: String?
    var onChange: (() -> Void)?
    var onLog: ((String) -> Void)?
    private var attemptedServiceQueries: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var queries: [SDPQuery] = []

    func refresh(forceServiceDiscovery: Bool = true) {
        guard !isRefreshing else { return }
        isRefreshing = true; message = nil
        refreshTask = Task {
            let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
            let connectedIDs = Set(paired.filter { $0.isConnected() }.compactMap(\.addressString))
            attemptedServiceQueries.formIntersection(connectedIDs)
            var found: [PairedHeadphone] = []
            var failures = 0
            // Cached Sony services are enough to list a device; the transport
            // tries that channel first, refreshing SDP only if opening fails.
            for device in paired where SonyServices.channelID(for: device) != nil {
                found.append(PairedHeadphone(device: device))
            }
            devices = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            onChange?()
            // Query only already-connected devices without cached Sony records.
            // Discovery must not connect every bonded keyboard/phone/headset.
            for device in paired where device.isConnected() && SonyServices.channelID(for: device) == nil {
                let id = device.addressString ?? ""
                guard forceServiceDiscovery || !attemptedServiceQueries.contains(id) else { continue }
                attemptedServiceQueries.insert(id)
                let query = SDPQuery(device: device, log: onLog ?? { _ in }); queries.append(query)
                do { try await query.run() } catch { failures += 1 }
                if SonyServices.channelID(for: device) != nil, !found.contains(where: { $0.id == device.addressString }) {
                    found.append(PairedHeadphone(device: device))
                }
            }
            devices = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if devices.isEmpty {
                message = "Connect your headphones in macOS Bluetooth settings, then refresh."
                if failures > 0 { message! += " Service discovery failed; check Bluetooth permission." }
            }
            isRefreshing = false
            onChange?()
        }
    }
}
