import SwiftUI
import TandemCore

struct ListeningModeSection: View {
    @ObservedObject var model: HeadphoneModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Listening Mode")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 3)
            ForEach(ListeningMode.allCases, id: \.self) { mode in
                modeRow(mode)
            }
            if let status = model.listeningPresentation.confirmed,
               let range = status.ambientLevelRange, let level = status.ambientLevel, range.contains(level) {
                AmbientLevelControl(model: model, reportedLevel: level, range: range)
                    .padding(.leading, 27)
                    .padding(.vertical, 5)
            }
            Text(model.state.listeningIssue ?? (model.state.listening?.isChanging == true ? "Headphones are changing modes…" : " "))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .topLeading)
                .help(model.state.listeningIssue ?? "")
                .accessibilityHidden(model.state.listeningIssue == nil && model.state.listening?.isChanging != true)
        }
    }

    private func modeRow(_ mode: ListeningMode) -> some View {
        let selected = model.listeningPresentation.confirmed?.mode == mode
        let supported = model.state.availableListeningModes.contains(mode)
        return Button { model.setListeningMode(mode) } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.body.weight(.medium))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 17)
                    .accessibilityHidden(true)
                Image(systemName: symbol(for: mode))
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(mode.title).font(.body)
                Spacer(minLength: 0)
                ProgressView().controlSize(.small)
                    .frame(width: 16, height: 16)
                    .opacity(model.changingListeningMode == mode ? 1 : 0)
                    .accessibilityHidden(model.changingListeningMode != mode)
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.busy || !supported || !model.state.canChangeListeningMode)
        .accessibilityLabel(mode.title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .help(supported ? "Set listening mode to \(mode.title)" : "Unavailable for this device's implemented protocol profile")
    }

    private func symbol(for mode: ListeningMode) -> String {
        switch mode {
        case .noiseCancelling: return "waveform"
        case .ambient: return "ear"
        case .normal: return "speaker.wave.2"
        }
    }
}

/// Draft values stay local during a drag; one settled command is sent on release.
private struct AmbientLevelControl: View {
    @ObservedObject var model: HeadphoneModel
    let reportedLevel: Int
    let range: ClosedRange<Int>
    @State private var draft: Double = 1
    @State private var editing = false
    @State private var pendingLevel: Int?
    @State private var pendingAdjustment: Task<Void, Never>?

    private var displayedLevel: Int { editing ? Int(draft) : (pendingLevel ?? reportedLevel) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(pendingLevel == nil ? "Ambient Sound" : "Ambient Sound · Applying…").lineLimit(1)
                Spacer()
                Text("\(displayedLevel) / \(range.upperBound)").monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(displayedLevel) },
                                  set: { value in
                                      draft = value
                                      // Keyboard edits can arrive without a drag lifecycle.
                                      // Defer until callbacks finish so a mouse-down can
                                      // mark editing before we decide to send.
                                      pendingAdjustment?.cancel()
                                      pendingAdjustment = Task { @MainActor in
                                          await Task.yield()
                                          guard !Task.isCancelled, !editing else { return }
                                          commit(Int(value))
                                      }
                                  }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1,
                   onEditingChanged: { active in
                       pendingAdjustment?.cancel()
                       if active { draft = Double(reportedLevel) }
                       editing = active
                       if !active { commit(Int(draft)) }
                   })
                .accessibilityLabel("Ambient sound level")
                .accessibilityValue("\(displayedLevel) of \(range.upperBound)")
                .accessibilityAdjustableAction { direction in
                    let increment: Int
                    switch direction {
                    case .increment: increment = 1
                    case .decrement: increment = -1
                    @unknown default: return
                    }
                    let level = min(range.upperBound, max(range.lowerBound, reportedLevel + increment))
                    if level != reportedLevel { commit(level) }
                }
            HStack {
                Text("Less ambient sound")
                Spacer()
                Text("More")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .disabled(model.busy || !model.state.canChangeListeningMode || model.state.listening?.mode != .ambient)
        .onChange(of: model.state.canChangeListeningMode) { canChange in
            if !canChange { pendingAdjustment?.cancel(); editing = false }
        }
        .onChange(of: model.state.listening?.mode) { mode in
            if let mode, mode != .ambient {
                pendingAdjustment?.cancel(); editing = false; pendingLevel = nil
            }
        }
        .onChange(of: model.busy) { busy in
            if !busy { pendingLevel = nil }
        }
        .onDisappear { pendingAdjustment?.cancel() }
    }

    private func commit(_ level: Int) {
        guard !model.busy, model.state.canChangeListeningMode,
              model.state.listening?.mode == .ambient,
              level != reportedLevel else { return }
        pendingLevel = level
        model.setAmbientLevel(level)
    }
}
