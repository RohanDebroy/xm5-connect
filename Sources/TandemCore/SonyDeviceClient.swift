import Foundation

/// Descriptor semantics are an explicit compatibility policy, never inferred
/// from a model name. The independent SonyHeadphonesClient implementation calls
/// this byte priority; initial protocol notes call it a version. Preserve it raw.
public enum DescriptorPolicy {
    case referencePriority
    case capabilityVersions(Set<UInt8>)

    func accepts(_ value: UInt8?) -> Bool {
        guard let value else { return false }
        switch self {
        case .referencePriority: return true
        case .capabilityVersions(let supported): return supported.contains(value)
        }
    }
}

public struct HeadphoneState {
    public var battery: BatteryStatus?
    public var peripherals: PeripheralSnapshot?
    public var sourceCapacity: Int?
    public var batteryIssue: String?
    public var peripheralIssue: String?
    public var switchIssue: String?
    public var canSwitch = false
    public var listening: ListeningStatus?
    public var availableListeningModes: [ListeningMode] = []
    public var listeningIssue: String?
    public var canChangeListeningMode: Bool { listening != nil && listening?.isChanging == false }
    public init() {}
}

/// Coordinates independent feature services without exposing Bluetooth or UI.
/// Only the documented single-battery and Classic peripheral variants exist
/// here; new layouts can be added without changing transport or framing.
@MainActor
public final class SonyDeviceClient {
    public private(set) var state = HeadphoneState() { didSet { onChange?(state) } }
    public private(set) var capabilities = CapabilityRegistry()
    public var onChange: ((HeadphoneState) -> Void)?
    public var onClosed: ((Error) -> Void)?
    public var onLog: ((String) -> Void)?
    public var isOpen: Bool { session.isOpen }
    private let session: TandemSession
    private let descriptorPolicy: DescriptorPolicy
    private var batteryEnabled = false
    private var peripheralsEnabled = false
    private var peripheralListType: UInt8 = 0
    private var sourceSwitchAdvertised = false
    private var listeningProfile: ListeningProfile?
    private var listeningObservation: UInt64 = 0
    private var operating = false
    private var revision = UUID()

    public init(session: TandemSession, descriptorPolicy: DescriptorPolicy) {
        self.session = session; self.descriptorPolicy = descriptorPolicy
        session.onLog = { [weak self] in self?.onLog?($0) }
        session.onNotification = { [weak self] in self?.notification($0) }
        session.onMessage = { [weak self] in self?.observeListening($0) }
        session.onClosed = { [weak self] error in
            guard let self else { return }
            self.revision = UUID(); self.clear()
            self.onClosed?(error)
        }
    }

    public func start() async throws {
        guard !operating else { throw TandemError.busy }
        operating = true
        defer { operating = false }
        clear(); capabilities = CapabilityRegistry(); revision = UUID()
        let currentRevision = revision
        try await session.open()
        guard try await session.initialize() == .v2 else {
            session.stop()
            throw TandemError.unsupported("This device uses Tandem v1. This app currently implements v2 feature layouts.")
        }
        let info = try await get(table: 0x0c, command: 2, reply: 3)
        guard info.count > 4, info[1] == 0, info.count == 4 + Int(info[3]) else {
            throw TandemError.malformed("capability identifier")
        }
        capabilities.record(table: 0x0c, payload: info)
        do {
            try capabilities.ingest(table: 0x0c, payload: await get(table: 0x0c, command: 6, reply: 7))
        } catch {
            guard session.isOpen, currentRevision == revision else { throw error }
            state.batteryIssue = error.localizedDescription
        }
        batteryEnabled = descriptorPolicy.accepts(capabilities.version(table: 0x0c, function: 0x20))
        if !batteryEnabled && state.batteryIssue == nil {
            state.batteryIssue = "The documented single-battery feature is unavailable on this device."
        }
        // Load battery before optional multipoint negotiation can stall.
        try await refreshFeatures(revision: currentRevision, includePeripherals: false, includeListening: false)
        listeningProfile = ListeningProfile.negotiate(capabilities, policy: descriptorPolicy)
        state.availableListeningModes = listeningProfile?.modes ?? []
        if listeningProfile == nil {
            state.listeningIssue = "The advertised listening-mode format is not implemented for this device."
        }
        onLog?("Listening-mode request type: \(String(describing: listeningProfile?.inquiredType))")
        do {
            try capabilities.ingest(table: 0x0e, payload: await get(table: 0x0e, command: 6, reply: 7))
        } catch {
            guard session.isOpen, currentRevision == revision else { throw error }
            state.peripheralIssue = error.localizedDescription
        }
        guard currentRevision == revision else { throw TandemError.disconnected }
        let supportsClassic = descriptorPolicy.accepts(capabilities.version(table: 0x0e, function: 0x30))
        let supportsDeviceClass = [UInt8(0x32), 0x33].contains {
            descriptorPolicy.accepts(capabilities.version(table: 0x0e, function: $0))
        }
        peripheralsEnabled = supportsClassic || supportsDeviceClass
        peripheralListType = supportsDeviceClass ? 2 : 0
        sourceSwitchAdvertised = descriptorPolicy.accepts(capabilities.version(table: 0x0e, function: 0x31))
        onLog?("Support descriptor policy: \(descriptorPolicy). Raw functions: \(capabilities.functions)")
        onLog?("Peripheral list enabled=\(peripheralsEnabled), request type=\(peripheralListType), source switching advertised=\(sourceSwitchAdvertised)")
        if !peripheralsEnabled && state.peripheralIssue == nil {
            state.peripheralIssue = "This device does not advertise a supported Classic or device-class audio-device list."
        }
        // The fixed GET_PARAM/source-switch formats do not require a capacity
        // inquiry. Some firmware does not answer that optional inquiry. Ask for
        // the advertised list directly; never let a count probe block it.
        try await refreshFeatures(revision: currentRevision, includeBattery: false)
    }

    public func refresh() async throws {
        guard !operating else { throw TandemError.busy }
        operating = true
        defer { operating = false }
        try await refreshFeatures(revision: revision)
    }

    public func switchSource(_ address: String) async throws -> SourceSwitchResult {
        guard !operating else { throw TandemError.busy }
        guard state.canSwitch else { throw TandemError.unsupported(state.switchIssue ?? "Source switching is unavailable.") }
        guard state.peripherals?.connected.contains(where: { $0.address == address.uppercased() }) == true else {
            throw TandemError.unsupported("Choose a currently connected audio source.")
        }
        operating = true
        defer { operating = false }
        let currentRevision = revision
        let reply = try await session.request(table: 0x0e, payload: PeripheralCommands.switchSource(address),
                                              matching: ReplyMatcher(table: 0x0e, command: 0x3d, type: 1, address: address))
        guard currentRevision == revision else { throw TandemError.disconnected }
        let result = try SourceSwitchResult.parse(reply.payload)
        if result.succeeded {
            // Acceptance is not evidence of playback. Re-read device state.
            do {
                let raw = try await get(table: 0x0e, command: 0x36, reply: 0x37, type: peripheralListType)
                guard currentRevision == revision else { throw TandemError.disconnected }
                state.peripherals = try PeripheralSnapshot.parse(raw)
                state.peripheralIssue = nil
                updateSwitchAvailability()
            } catch {
                guard session.isOpen, currentRevision == revision else { throw error }
                state.peripherals = nil
                updateSwitchAvailability()
                state.peripheralIssue = "Switch accepted, but refreshing the source list failed: \(error.localizedDescription)"
            }
        }
        return result
    }

    public func setListeningMode(_ mode: ListeningMode) async throws -> ListeningStatus {
        try await changeListening(.mode(mode))
    }

    public func setAmbientLevel(_ level: Int) async throws -> ListeningStatus {
        guard let range = state.listening?.ambientLevelRange, range.contains(level) else {
            throw TandemError.unsupported("Ambient level is unavailable or outside the supported range.")
        }
        return try await changeListening(.ambientLevel(level))
    }

    private enum ListeningChange {
        case mode(ListeningMode), ambientLevel(Int)
        func command(from status: ListeningStatus) throws -> [UInt8] {
            switch self {
            case .mode(let mode): return try status.command(for: mode)
            case .ambientLevel(let level): return try status.command(ambientLevel: level)
            }
        }
        func isConfirmed(by status: ListeningStatus) -> Bool {
            switch self {
            case .mode(let mode): return status.mode == mode
            case .ambientLevel(let level): return status.mode == .ambient && status.ambientLevel == level
            }
        }
    }

    private func changeListening(_ change: ListeningChange) async throws -> ListeningStatus {
        guard !operating else { throw TandemError.busy }
        guard let profile = listeningProfile else {
            throw TandemError.unsupported("This listening mode is unavailable for the advertised device profile.")
        }
        guard session.isOpen else { throw TandemError.disconnected }
        operating = true
        defer { operating = false }
        let currentRevision = revision
        let confirmed: ListeningStatus
        var lastObservation = listeningObservation
        do {
            // Re-read before writing so another app/hardware button's latest
            // ambient level and adaptation/voice settings are preserved.
            _ = try await readListening(profile, revision: currentRevision)
            guard let latest = state.listening, latest.profile == profile else {
                throw TandemError.malformed("latest listening-mode state; refresh before changing modes")
            }
            let command = try change.command(from: latest)
            lastObservation = listeningObservation
            let reply = try await session.request(table: 0x0c, payload: command,
                matching: ReplyMatcher(table: 0x0c, command: 0x69, type: profile.inquiredType, requiresSettledChange: true),
                validateBeforeSend: { [weak self] in
                    guard let self, self.revision == currentRevision else { throw TandemError.disconnected }
                    guard let current = self.state.listening,
                          try change.command(from: current) == command else {
                        throw TandemError.unsupported("Listening settings changed before sending. Try again with the current settings.")
                    }
                })
            guard currentRevision == revision else { throw TandemError.disconnected }
            confirmed = try ListeningStatus.parse(reply.payload, profile: profile)
        } catch {
            if currentRevision == revision, session.isOpen {
                if listeningObservation == lastObservation { state.listening = nil }
                state.listeningIssue = error.localizedDescription
            }
            throw error
        }
        // State was applied synchronously in receive order. A newer hardware
        // notification may already have superseded this confirmation.
        guard change.isConfirmed(by: confirmed) else {
            let error = TandemError.unsupported("The headphones did not confirm the requested listening settings. The reported selection is shown.")
            state.listeningIssue = error.localizedDescription
            throw error
        }
        return confirmed
    }

    public func stop() {
        revision = UUID(); session.stop(); clear()
    }

    private func refreshFeatures(revision currentRevision: UUID, includeBattery: Bool = true, includePeripherals: Bool = true, includeListening: Bool = true) async throws {
        guard session.isOpen else { throw TandemError.disconnected }
        if batteryEnabled && includeBattery {
            do {
                let raw = try await get(table: 0x0c, command: 0x22, reply: 0x23)
                guard currentRevision == revision else { throw TandemError.disconnected }
                state.battery = try BatteryStatus.parse(raw); state.batteryIssue = nil
            } catch {
                guard session.isOpen, currentRevision == revision else { throw error }
                state.battery = nil; state.batteryIssue = error.localizedDescription
            }
        }
        if peripheralsEnabled && includePeripherals {
            do {
                onLog?("Requesting connected audio devices: table 2 GET_PARAM, type \(peripheralListType)")
                let raw = try await get(table: 0x0e, command: 0x36, reply: 0x37, type: peripheralListType)
                guard currentRevision == revision else { throw TandemError.disconnected }
                state.peripherals = try PeripheralSnapshot.parse(raw); state.peripheralIssue = nil
                updateSwitchAvailability()
            } catch {
                guard session.isOpen, currentRevision == revision else { throw error }
                state.peripherals = nil; state.peripheralIssue = error.localizedDescription
                updateSwitchAvailability()
            }
        }
        if includeListening, let profile = listeningProfile {
            let beforeRead = listeningObservation
            do { _ = try await readListening(profile, revision: currentRevision) }
            catch {
                guard session.isOpen, currentRevision == revision else { throw error }
                if listeningObservation == beforeRead {
                    state.listening = nil
                    state.listeningIssue = error.localizedDescription
                }
            }
        }
    }

    private func readListening(_ profile: ListeningProfile, revision currentRevision: UUID) async throws -> ListeningStatus {
        let raw = try await get(table: 0x0c, command: 0x66, reply: 0x67, type: profile.inquiredType)
        guard currentRevision == revision else { throw TandemError.disconnected }
        return try ListeningStatus.parse(raw, profile: profile)
    }

    private func get(table: UInt8, command: UInt8, reply: UInt8, type: UInt8 = 0) async throws -> [UInt8] {
        try await session.request(table: table, payload: [command, type],
                                  matching: ReplyMatcher(table: table, command: reply, type: type)).payload
    }

    private func notification(_ frame: Frame) {
        do {
            if batteryEnabled, frame.dataType == 0x0c, frame.payload.starts(with: [0x25, 0]) {
                state.battery = try BatteryStatus.parse(frame.payload); state.batteryIssue = nil
            } else if peripheralsEnabled, frame.dataType == 0x0e, frame.payload.starts(with: [0x39, peripheralListType]) {
                state.peripherals = try PeripheralSnapshot.parse(frame.payload); state.peripheralIssue = nil
                updateSwitchAvailability()
            }
        } catch { onLog?("Ignored malformed notification: \(error.localizedDescription)") }
    }

    private func observeListening(_ frame: Frame) {
        guard let profile = listeningProfile, frame.dataType == 0x0c, frame.payload.count >= 2,
              [0x67, 0x69].contains(frame.payload[0]), frame.payload[1] == profile.inquiredType else { return }
        listeningObservation &+= 1
        do {
            state.listening = try ListeningStatus.parse(frame.payload, profile: profile)
            state.listeningIssue = nil
        } catch {
            state.listening = nil
            state.listeningIssue = error.localizedDescription
            onLog?("Invalid listening-mode report: \(error.localizedDescription)")
        }
    }

    private func updateSwitchAvailability() {
        let hasConnectedTargets = state.peripherals?.connected.isEmpty == false
        let capacityAllowsSwitch = state.sourceCapacity.map { $0 > 0 } ?? true
        state.canSwitch = sourceSwitchAdvertised && hasConnectedTargets && capacityAllowsSwitch
        state.switchIssue = sourceSwitchAdvertised ? nil : "Source switching is not advertised by this device."
    }

    private func clear() {
        batteryEnabled = false; peripheralsEnabled = false; sourceSwitchAdvertised = false
        peripheralListType = 0; listeningProfile = nil; listeningObservation = 0; state = HeadphoneState()
    }
}
