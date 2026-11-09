import Foundation

public enum ListeningMode: String, CaseIterable, Hashable, Sendable {
    case noiseCancelling, ambient, normal

    public var title: String {
        switch self {
        case .noiseCancelling: return "Noise Cancellation"
        case .ambient: return "Transparency"
        case .normal: return "Normal (Off)"
        }
    }
}

/// Exact v2 formats independently described by ProtocolV2T1.h and the supplied
/// raw enums. No universal-command fallback is used for other NCASM variants.
public enum ListeningProfile: CaseIterable, Sendable {
    case ncAmbient, ncAmbientAdaptive, ambientLevel, ambientOnOff

    public var function: UInt8 {
        switch self { case .ncAmbient: return 0x6b; case .ncAmbientAdaptive: return 0x6d
        case .ambientLevel: return 0x67; case .ambientOnOff: return 0x66 }
    }
    public var inquiredType: UInt8 {
        switch self { case .ncAmbient: return 0x17; case .ncAmbientAdaptive: return 0x19
        case .ambientLevel: return 0x22; case .ambientOnOff: return 0x21 }
    }
    var payloadLength: Int {
        switch self { case .ncAmbient: return 7; case .ncAmbientAdaptive: return 9
        case .ambientLevel, .ambientOnOff: return 6 }
    }
    var hasANC: Bool { self == .ncAmbient || self == .ncAmbientAdaptive }
    public var modes: [ListeningMode] { hasANC ? ListeningMode.allCases : [.ambient, .normal] }

    public static func negotiate(_ registry: CapabilityRegistry, policy: DescriptorPolicy) -> Self? {
        allCases.first { policy.accepts(registry.version(table: 0x0c, function: $0.function)) }
    }
}

public struct ListeningStatus: Equatable, Sendable {
    public let profile: ListeningProfile
    private let payload: [UInt8]
    public var isChanging: Bool { payload[2] == 0 }
    public var mode: ListeningMode? {
        guard !isChanging else { return nil }
        guard payload[3] == 1 else { return .normal }
        if profile.hasANC { return payload[4] == 0 ? .noiseCancelling : .ambient }
        if profile == .ambientOnOff && payload[5] == 0 { return .normal }
        return .ambient
    }

    // Gadgetbridge's seven-byte NC/ASM v2 profile exposes steps 1...20.
    // Other profiles keep mode switching, without guessing their slider range.
    public var ambientLevelRange: ClosedRange<Int>? { profile == .ncAmbient ? 1...20 : nil }
    public var ambientLevel: Int? { ambientLevelRange == nil ? nil : Int(payload[6]) }

    public func command(ambientLevel: Int) throws -> [UInt8] {
        guard let range = ambientLevelRange, range.contains(ambientLevel) else {
            throw TandemError.unsupported("Ambient level is unavailable or outside the supported range.")
        }
        guard mode == .ambient else {
            throw TandemError.unsupported("Select Transparency before changing its level.")
        }
        var command = try command(for: .ambient)
        command[6] = UInt8(ambientLevel)
        return command
    }

    public static func parse(_ bytes: [UInt8], profile: ListeningProfile) throws -> Self {
        guard bytes.count == profile.payloadLength, [0x67, 0x69].contains(bytes[0]),
              bytes[1] == profile.inquiredType, bytes[2] <= 1, bytes[3] <= 1 else {
            throw TandemError.malformed("listening-mode parameters")
        }
        if profile.hasANC {
            guard bytes[4] <= 1, bytes[5] <= 1 else { throw TandemError.malformed("NC/ambient mode values") }
        } else {
            guard bytes[4] <= 1 else { throw TandemError.malformed("ambient voice mode") }
            if profile == .ambientOnOff, bytes[5] > 1 { throw TandemError.malformed("ambient on/off value") }
        }
        if profile == .ncAmbient, bytes[6] > 20 {
            throw TandemError.malformed("ambient sound level")
        }
        if profile == .ncAmbientAdaptive {
            guard bytes[7] <= 1, bytes[8] <= 2 else { throw TandemError.malformed("noise-adaptation values") }
        }
        return Self(profile: profile, payload: bytes)
    }

    /// Change only the mode fields. Preserve the device's current level, voice
    /// focus and adaptation settings.
    public func command(for mode: ListeningMode) throws -> [UInt8] {
        guard !isChanging else { throw TandemError.busy }
        guard profile.modes.contains(mode) else {
            throw TandemError.unsupported("This device's implemented listening profile does not support \(mode.title).")
        }
        var command = payload
        command[0] = 0x68 // NCASM_SET_PARAM, v2 table 1
        command[2] = 1 // Final discrete change, not a continuous slider gesture.
        command[3] = mode == .normal ? 0 : 1
        if profile.hasANC, mode != .normal { command[4] = mode == .noiseCancelling ? 0 : 1 }
        if mode == .ambient {
            let levelIndex = profile.hasANC ? 6 : 5
            // The reference's discrete mode setter uses max(currentLevel, 1).
            // Preserve a nonzero observed level rather than inventing a preset.
            command[levelIndex] = profile == .ambientOnOff ? 1 : max(command[levelIndex], 1)
        }
        return command
    }
}
