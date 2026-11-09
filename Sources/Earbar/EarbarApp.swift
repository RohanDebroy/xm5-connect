import AppKit
import SwiftUI
import TandemCore

@main
struct EarbarApp: App {
    @StateObject private var model = HeadphoneModel()

    var body: some Scene {
        MenuBarExtra {
            HeadphonePanel(model: model, catalog: model.catalog)
        } label: {
            Label(model.menuLabel.isEmpty ? "Earbar" : model.menuLabel, systemImage: "headphones")
                .labelStyle(MenuBarLabelStyle(hasBattery: !model.menuLabel.isEmpty))
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabelStyle: LabelStyle {
    let hasBattery: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            if hasBattery { configuration.title }
        }
    }
}

struct HeadphonePanel: View {
    @ObservedObject var model: HeadphoneModel
    @ObservedObject var catalog: DeviceCatalog

    var body: some View {
        VStack(spacing: 0) {
            header.padding(16)
            Divider()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    deviceSelection
                    if model.phase == .connected {
                        battery
                        Divider()
                        ListeningModeSection(model: model)
                        Divider()
                        sources
                    } else {
                        Text(model.phase.isConnecting ? "Opening the headphone control connection…" : (model.autoConnectEnabled ? "Waiting for connected Sony headphones. Battery and audio devices load automatically." : "Automatic connection paused. Click Connect to resume."))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 370, height: 640)
        .transaction { $0.animation = nil }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "headphones").font(.system(size: 28, weight: .light))
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text("Earbar").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(model.phase == .connected ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(model.message ?? model.phase.label)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(model.message ?? model.phase.label)
                }
            }
            Spacer()
            ProgressView().controlSize(.small)
                .frame(width: 16, height: 16)
                .opacity(model.busy || model.phase.isConnecting ? 1 : 0)
                .accessibilityLabel("Device operation in progress")
                .accessibilityHidden(!model.busy && !model.phase.isConnecting)
        }
    }

    private var deviceSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HEADPHONES TO CONTROL").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { catalog.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(catalog.isRefreshing || model.phase.isConnecting || model.busy)
                    .help("Refresh paired Sony devices")
                    .accessibilityLabel("Refresh paired devices")
            }
            Picker("Device", selection: $model.selectedID) {
                Text("Choose a device…").tag("")
                if !model.selectedID.isEmpty && !catalog.devices.contains(where: { $0.id == model.selectedID }) {
                    Text("Saved device unavailable").tag(model.selectedID)
                }
                ForEach(catalog.devices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
            if let message = catalog.message, catalog.devices.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Bluetooth Settings", action: openBluetoothSettings).buttonStyle(.link)
            }
        }
    }

    private var battery: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Battery").font(.subheadline.weight(.medium))
                Text(chargingLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let battery = model.state.battery {
                Image(systemName: battery.charging == .charging ? "battery.100.bolt" : batterySymbol(battery.level))
                    .font(.title3).accessibilityHidden(true)
                Text("\(battery.level)%").font(.title2.monospacedDigit().weight(.medium))
                    .accessibilityLabel("Battery \(battery.level) percent")
            } else { Text("—").font(.title2).accessibilityLabel("Battery unavailable") }
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CONNECTED AUDIO DEVICES").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let sources = model.state.peripherals {
                    Text("\(sources.connected.count) connected").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let issue = model.state.peripheralIssue {
                Text(issue).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let snapshot = model.state.peripherals {
                if snapshot.connected.isEmpty {
                    Text("No connected sources reported.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(snapshot.connected) { source in
                    HStack(spacing: 10) {
                        Image(systemName: "waveform").foregroundStyle(.secondary).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name).font(.subheadline.weight(.medium)).lineLimit(2)
                            Text(snapshot.selectedAddress == source.address ? "Current audio source (reported)" : "Connected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button { model.switchSource(source) } label: {
                            Text("Use for audio")
                                .opacity(model.switchingAddress == source.address ? 0 : 1)
                                .overlay {
                                    if model.switchingAddress == source.address { ProgressView().controlSize(.small) }
                                }
                        }
                            .controlSize(.small)
                            .disabled(model.busy || !model.state.canSwitch)
                            .accessibilityLabel("Switch audio source to \(source.name)")
                    }
                    .padding(.vertical, 3)
                }
                if snapshot.selectedAddress == nil && !snapshot.connected.isEmpty {
                    Text("Current selection is unknown.").font(.caption).foregroundStyle(.secondary)
                }
                let remembered = snapshot.devices.filter { !$0.isConnected }
                if !remembered.isEmpty {
                    Text("Remembered · " + remembered.map(\.name).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let issue = model.state.switchIssue {
                Text(issue).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.phase == .connected || model.phase.isConnecting {
                Button(model.phase.isConnecting ? "Cancel" : "Disconnect") { model.disconnect() }
                    .help("Close the control connection; keep the audio connection")
            } else {
                Button("Connect") { model.connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!catalog.devices.contains(where: { $0.id == model.selectedID }))
            }
            if model.phase == .connected {
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.busy).help("Refresh battery and sources").accessibilityLabel("Refresh headphone status")
            }
            Spacer()
            Menu {
                Button("Copy Diagnostics") { model.copyDiagnostics() }
                Button("Bluetooth Settings", action: openBluetoothSettings)
                Divider()
                Button("Quit Earbar") { model.disconnect(); NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("App options")
        }
        .controlSize(.small)
    }

    private var chargingLabel: String {
        guard let battery = model.state.battery else { return model.state.batteryIssue ?? "Waiting for a reading" }
        switch battery.charging {
        case .charging: return "Charging"
        case .charged: return "Fully charged"
        case .notCharging: return "Not charging"
        case .unknown: return "Charging state unknown"
        }
    }
    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case 0..<13: return "battery.0"
        case 13..<38: return "battery.25"
        case 38..<63: return "battery.50"
        case 63..<88: return "battery.75"
        default: return "battery.100"
        }
    }
    private func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }
}
