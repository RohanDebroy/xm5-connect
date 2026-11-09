import Foundation

public enum TandemError: Error, LocalizedError, Equatable {
    case malformed(String), unsupported(String), disconnected, busy, timedOut(String), transport(String)
    public var errorDescription: String? {
        switch self {
        case .malformed(let detail): return "Invalid device response: \(detail)"
        case .unsupported(let detail): return detail
        case .disconnected: return "The control connection closed."
        case .busy: return "Another device operation is in progress."
        case .timedOut(let detail): return "Timed out waiting for \(detail)."
        case .transport(let detail): return detail
        }
    }
}

public enum ProtocolGeneration: Equatable {
    case v1, v2
    public static func detect(_ payload: [UInt8]) throws -> Self {
        guard payload.first == 1, payload.count == 4 || payload.count == 8 else {
            throw TandemError.malformed("protocol generation")
        }
        return payload.count == 8 ? .v2 : .v1
    }
}

public struct CapabilityRegistry {
    public private(set) var functions: [UInt8: [UInt8: UInt8]] = [:]
    public private(set) var rawResponses: [String: [UInt8]] = [:]
    public init() {}

    public mutating func ingest(table: UInt8, payload: [UInt8]) throws {
        guard payload.count >= 3, payload[0] == 7, payload[1] == 0,
              payload.count == 3 + Int(payload[2]) * 2 else { throw TandemError.malformed("support functions") }
        var entries: [UInt8: UInt8] = [:]
        for i in stride(from: 3, to: payload.count, by: 2) {
            guard entries[payload[i]] == nil else { throw TandemError.malformed("duplicate support function") }
            entries[payload[i]] = payload[i + 1]
        }
        functions[table] = entries
        record(table: table, payload: payload)
    }
    public mutating func record(table: UInt8, payload: [UInt8]) {
        guard payload.count >= 2 else { return }
        rawResponses["\(table):\(payload[0]):\(payload[1])"] = payload
    }
    public func version(table: UInt8, function: UInt8) -> UInt8? { functions[table]?[function] }
    public func allows(table: UInt8, function: UInt8, supportedVersions: Set<UInt8>) -> Bool {
        guard let version = version(table: table, function: function) else { return false }
        return supportedVersions.contains(version)
    }
}

public struct BatteryStatus: Equatable {
    public enum Charging: Equatable { case notCharging, charging, charged, unknown }
    public let level: Int
    public let charging: Charging
    public static func parse(_ p: [UInt8]) throws -> Self {
        guard p.count == 4, [0x23, 0x25].contains(p[0]), p[1] == 0, p[2] <= 100 else {
            throw TandemError.malformed("single battery status")
        }
        let charging: Charging
        switch p[3] { case 0: charging = .notCharging; case 1: charging = .charging
        case 3: charging = .charged; default: charging = .unknown }
        return Self(level: Int(p[2]), charging: charging)
    }
}

public struct AudioSource: Identifiable, Equatable {
    public var id: String { address }
    public let address: String
    public let name: String
    public let connectionStatus: UInt8
    public let bluetoothClassOfDevice: UInt32?
    public var isConnected: Bool { connectionStatus > 0 }
}

public struct PeripheralSnapshot: Equatable {
    public let devices: [AudioSource]
    public let selectedAddress: String?
    public var connected: [AudioSource] { devices.filter(\.isConnected) }

    public static func parse(_ p: [UInt8]) throws -> Self {
        guard p.count >= 3, [0x37, 0x39].contains(p[0]), [0, 2].contains(p[1]) else {
            throw TandemError.malformed("device list header")
        }
        let includesDeviceClass = p[1] == 2
        let nameLengthOffset = includesDeviceClass ? 21 : 18
        var offset = 3
        var devices: [AudioSource] = []
        for _ in 0..<Int(p[2]) {
            guard offset + nameLengthOffset + 1 <= p.count else { throw TandemError.malformed("truncated device entry") }
            let address = String(decoding: p[offset..<offset + 17], as: UTF8.self)
            guard PeripheralCommands.isAddress(address), !devices.contains(where: { $0.address == address.uppercased() }) else {
                throw TandemError.malformed("device address")
            }
            let status = p[offset + 17], count = Int(p[offset + nameLengthOffset])
            let deviceClass: UInt32? = includesDeviceClass
                ? (UInt32(p[offset + 18]) << 16) | (UInt32(p[offset + 19]) << 8) | UInt32(p[offset + 20])
                : nil
            offset += nameLengthOffset + 1
            guard (0...128).contains(count), offset + count <= p.count else {
                throw TandemError.malformed("device name length")
            }
            let name = count == 0 ? address.uppercased() : String(decoding: p[offset..<offset + count], as: UTF8.self)
            offset += count
            devices.append(AudioSource(address: address.uppercased(), name: name, connectionStatus: status, bluetoothClassOfDevice: deviceClass))
        }
        guard p.count == offset || p.count == offset + 1 else { throw TandemError.malformed("device list trailer") }
        let selected = offset < p.count ? Int(p[offset]) : -1
        let selectedAddress = devices.indices.contains(selected) && devices[selected].isConnected ? devices[selected].address : nil
        return Self(devices: devices, selectedAddress: selectedAddress)
    }
}

public struct PeripheralCapability {
    public let sourceCount: Int
    public let sinkCount: Int
    public static func parse(_ p: [UInt8], type: UInt8 = 0) throws -> Self {
        guard p.count == 5, p[0] == 0x31, p[1] == type, p[4] <= 1 else {
            throw TandemError.malformed("peripheral capability")
        }
        return Self(sourceCount: Int(p[2]), sinkCount: Int(p[3]))
    }
}

public enum PeripheralCommands {
    public static func isAddress(_ address: String) -> Bool {
        let bytes = Array(address.utf8)
        guard bytes.count == 17 else { return false }
        return bytes.enumerated().allSatisfy { index, byte in
            if index % 3 == 2 { return byte == 0x3a }
            return (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
    public static func switchSource(_ address: String) throws -> [UInt8] {
        guard isAddress(address) else { throw TandemError.malformed("source address") }
        return [0x3c, 1] + Array(address.uppercased().utf8)
    }
}

public struct SourceSwitchResult {
    public let address: String
    public let code: UInt8
    public var succeeded: Bool { code == 0 }
    public var message: String {
        switch code {
        case 0: return "Switch accepted by headphones."
        case 1: return "The headphones could not switch sources."
        case 2: return "Cannot switch during a call."
        case 3: return "The target device has no connected media link."
        case 4: return "The voice assistant currently has priority."
        default: return "Unknown source-switch result (\(code))."
        }
    }
    public static func parse(_ p: [UInt8]) throws -> Self {
        guard p.count == 20, p[0] == 0x3d, p[1] == 1 else { throw TandemError.malformed("source switch result") }
        let address = String(decoding: p[3...], as: UTF8.self)
        guard PeripheralCommands.isAddress(address) else { throw TandemError.malformed("source switch address") }
        return Self(address: address.uppercased(), code: p[2])
    }
}
