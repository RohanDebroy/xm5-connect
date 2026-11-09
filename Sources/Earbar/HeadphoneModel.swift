import AppKit
import Combine
import Foundation
@preconcurrency import IOBluetooth
import TandemCore

@MainActor
final class HeadphoneModel: ObservableObject {
    enum Phase: Equatable {
        case idle, connecting, connected, reconnecting(Int), failed
        var label: String {
            switch self {
            case .idle: return "Not connected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .reconnecting(let attempt): return "Reconnecting (\(attempt)/3)…"
            case .failed: return "Connection unavailable"
            }
        }
        var isConnecting: Bool {
            switch self { case .connecting, .reconnecting: return true; default: return false }
        }
    }

    let catalog = DeviceCatalog()
    @Published var selectedID: String {
        didSet {
            guard selectedID != oldValue else { return }
            stopConnection()
            UserDefaults.standard.set(selectedID, forKey: "selectedHeadphone")
            if !selectingAutomatically {
                autoConnectEnabled = true
                if catalog.devices.contains(where: { $0.id == selectedID && $0.device.isConnected() }) { connect() }
            }
        }
    }
    @Published private(set) var autoConnectEnabled = true
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var state = HeadphoneState()
    @Published private(set) var busy = false
    @Published private(set) var switchingAddress: String?
    @Published private(set) var changingListeningMode: ListeningMode?
    @Published private(set) var message: String?
    @Published private(set) var updatedAt: Date?
    private var client: SonyDeviceClient?
    private var work: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var connectionToken = UUID()
    private var logs: [String] = []
    private var wantsConnection = false
    private var reconnectBudget = ReconnectBudget()
    private var selectingAutomatically = false
    private var autoAttemptedIDs: Set<String> = []
    private var monitoring: Task<Void, Never>?

    init() {
        selectedID = UserDefaults.standard.string(forKey: "selectedHeadphone") ?? ""
        catalog.onChange = { [weak self] in self?.considerAutoConnection() }
        catalog.onLog = { [weak self] in self?.log($0) }
        // Start with the app, not the popover: battery appears without opening it.
        monitoring = Task { [weak self] in
            self?.catalog.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                self?.catalog.refresh(forceServiceDiscovery: false)
            }
        }
    }

    private func considerAutoConnection() {
        let candidates = catalog.devices.map { HeadphoneCandidate(id: $0.id, name: $0.name, isConnected: $0.device.isConnected()) }
        autoAttemptedIDs.formIntersection(Set(candidates.filter(\.isConnected).map(\.id)))
        guard autoConnectEnabled, !phase.isConnecting, phase != .connected,
              let target = AutoConnectionPolicy.targetID(candidates: candidates, savedID: selectedID, output: SystemAudioOutput.current()),
              !autoAttemptedIDs.contains(target) else { return }
        selectingAutomatically = true
        selectedID = target
        selectingAutomatically = false
        log("Auto-connecting to connected headphones: \(target)")
        connect()
    }
    var selectedName: String { catalog.devices.first(where: { $0.id == selectedID })?.name ?? "Earbar" }
    var menuLabel: String {
        guard let battery = state.battery else { return "" }
        return "\(battery.level)%"
    }

    func connect() {
        guard !phase.isConnecting, let device = catalog.devices.first(where: { $0.id == selectedID })?.device else { return }
        autoConnectEnabled = true; autoAttemptedIDs.insert(selectedID)
        wantsConnection = true; reconnectBudget.reset()
        beginConnection(to: device)
    }

    private func beginConnection(to device: IOBluetoothDevice) {
        cancelCurrentConnection()
        let token = connectionToken
        phase = reconnectBudget.currentAttempt == 0 ? .connecting : .reconnecting(reconnectBudget.currentAttempt)
        message = nil; busy = true
        let session = TandemSession(transport: RFCOMMTransport(device: device, log: { [weak self] in self?.log($0) }))
        let newClient = SonyDeviceClient(session: session, descriptorPolicy: .referencePriority)
        client = newClient
        newClient.onLog = { [weak self] line in self?.log(line) }
        newClient.onChange = { [weak self] state in
            guard let self, self.connectionToken == token else { return }
            self.state = state
        }
        newClient.onClosed = { [weak self] error in
            guard let self, self.connectionToken == token else { return }
            self.handleLoss(error, device: device)
        }
        work = Task { [weak self] in
            do {
                try await newClient.start()
                guard let self, self.connectionToken == token else { return }
                self.reconnectBudget.connectionEstablished()
                self.phase = .connected; self.busy = false; self.updatedAt = Date()
                self.startPolling(token: token)
            } catch {
                guard let self, self.connectionToken == token else { return }
                self.handleLoss(error, device: device)
            }
        }
    }

    func disconnect() {
        autoConnectEnabled = false
        stopConnection()
    }

    private func stopConnection() {
        wantsConnection = false; reconnectBudget.reset()
        reconnect?.cancel(); reconnect = nil
        cancelCurrentConnection()
        phase = .idle; message = nil
    }

    func refresh() {
        guard phase == .connected, !busy, let client else { return }
        busy = true
        let token = connectionToken
        work = Task { [weak self] in
            do {
                try await client.refresh()
                guard let self, self.connectionToken == token else { return }
                self.message = nil; self.updatedAt = Date()
            } catch {
                guard let self, self.connectionToken == token else { return }
                self.message = error.localizedDescription
            }
            guard let self, self.connectionToken == token else { return }
            self.busy = false
        }
    }

    func switchSource(_ source: AudioSource) {
        guard phase == .connected, !busy, state.canSwitch, source.isConnected, let client else { return }
        busy = true; switchingAddress = source.address; message = nil
        let token = connectionToken
        work = Task { [weak self] in
            do {
                let result = try await client.switchSource(source.address)
                guard let self, self.connectionToken == token else { return }
                self.message = result.message
                self.updatedAt = Date()
            } catch {
                guard let self, self.connectionToken == token else { return }
                self.message = error.localizedDescription
            }
            guard let self, self.connectionToken == token else { return }
            self.busy = false; self.switchingAddress = nil
        }
    }

    func setListeningMode(_ mode: ListeningMode) {
        guard phase == .connected, !busy, state.canChangeListeningMode,
              state.availableListeningModes.contains(mode), let client else { return }
        busy = true; changingListeningMode = mode; message = nil
        let token = connectionToken
        work = Task { [weak self] in
            do {
                _ = try await client.setListeningMode(mode)
                guard let self, self.connectionToken == token else { return }
                self.updatedAt = Date()
            } catch {
                guard let self, self.connectionToken == token else { return }
                self.message = error.localizedDescription
            }
            guard let self, self.connectionToken == token else { return }
            self.busy = false; self.changingListeningMode = nil
        }
    }

    func setAmbientLevel(_ level: Int) {
        guard phase == .connected, !busy, state.canChangeListeningMode,
              state.listening?.mode == .ambient, let client else { return }
        busy = true; message = nil
        let token = connectionToken
        work = Task { [weak self] in
            do {
                _ = try await client.setAmbientLevel(level)
                guard let self, self.connectionToken == token else { return }
                self.updatedAt = Date()
            } catch {
                guard let self, self.connectionToken == token else { return }
                self.message = error.localizedDescription
            }
            guard let self, self.connectionToken == token else { return }
            self.busy = false
        }
    }

    func copyDiagnostics() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let report = "Earbar \(version) diagnostics\n" +
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n" +
            "State: \(phase.label)\n" +
            "Selected headphones: \(selectedName) (\(selectedID))\n" +
            "Descriptor policy: reference implementation priority field\n" +
            "Raw log contains Bluetooth addresses and device names.\n\n" + logs.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        message = "Diagnostics copied. They include device names and Bluetooth addresses."
    }

    private func startPolling(token: UUID) {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                guard let self, self.connectionToken == token else { return }
                if !self.busy { self.refresh() }
            }
        }
    }

    private func handleLoss(_ error: Error, device: IOBluetoothDevice) {
        // Invalidate the token before cancelling work so its catch block cannot
        // schedule a second reconnect for the same connection loss.
        cancelCurrentConnection()
        message = error.localizedDescription; log("Connection closed: \(error.localizedDescription)")
        if case TandemError.unsupported = error {
            wantsConnection = false; phase = .failed; return
        }
        guard wantsConnection, let attempt = reconnectBudget.nextAttempt() else {
            phase = .failed; return
        }
        phase = .reconnecting(attempt)
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000) } catch { return }
            guard let self, self.wantsConnection else { return }
            self.beginConnection(to: device)
        }
    }

    private func cancelCurrentConnection() {
        connectionToken = UUID()
        work?.cancel(); work = nil
        polling?.cancel(); polling = nil
        client?.stop(); client = nil
        state = HeadphoneState(); busy = false; switchingAddress = nil; changingListeningMode = nil; updatedAt = nil
    }

    private func log(_ line: String) {
        logs.append("\(ISO8601DateFormatter().string(from: Date())) \(line)")
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }
}
