import Foundation

/// A connected byte stream. Writes must preserve whole-frame ordering; transport
/// adapters own any chunking. Callbacks and methods run on the main actor.
@MainActor
public protocol TandemTransport: AnyObject {
    var onBytes: (([UInt8]) -> Void)? { get set }
    var onDisconnect: ((Error?) -> Void)? { get set }
    func connect() async throws
    func disconnect()
    func write(_ bytes: [UInt8]) async throws
}

public struct ReplyMatcher: Hashable {
    public let table: UInt8
    public let command: UInt8
    public let type: UInt8
    public let address: String?
    public let requiresSettledChange: Bool
    public init(table: UInt8, command: UInt8, type: UInt8, address: String? = nil, requiresSettledChange: Bool = false) {
        self.table = table; self.command = command; self.type = type
        self.address = address?.uppercased()
        self.requiresSettledChange = requiresSettledChange
    }
    public func matches(_ frame: Frame) -> Bool {
        guard frame.dataType == table, frame.payload.count >= 2,
              frame.payload[0] == command, frame.payload[1] == type else { return false }
        if requiresSettledChange, frame.payload.count < 3 || frame.payload[2] != 1 { return false }
        if let address {
            return (try? SourceSwitchResult.parse(frame.payload).address) == address
        }
        return true
    }
}
