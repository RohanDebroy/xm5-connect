import Foundation

public struct Frame: Equatable, Sendable {
    public let dataType: UInt8
    public let sequence: UInt8
    public let payload: [UInt8]

    public init(dataType: UInt8, sequence: UInt8, payload: [UInt8]) {
        self.dataType = dataType
        self.sequence = sequence
        self.payload = payload
    }

    public static func ack(for sequence: UInt8) -> Frame {
        Frame(dataType: 1, sequence: 1 - sequence, payload: [])
    }
}

public enum FrameCodec {
    public static func encode(_ frame: Frame) -> [UInt8] {
        precondition(frame.sequence <= 1 && frame.payload.count <= FrameParser.payloadLimit)
        let length = UInt32(frame.payload.count)
        var body = [frame.dataType, frame.sequence,
                    UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
                    UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)] + frame.payload
        body.append(body.reduce(0, &+))
        var wire: [UInt8] = [0x3e]
        for byte in body {
            if (0x3c...0x3e).contains(byte) { wire += [0x3d, byte & 0xef] }
            else { wire.append(byte) }
        }
        return wire + [0x3c]
    }
}

/// One parser per transport session; accepts arbitrary byte boundaries.
public struct FrameParser {
    public static let payloadLimit = 65_536
    private let maxPayload: Int
    private var body: [UInt8] = []
    private var active = false
    private var escaped = false

    public init(maxPayload: Int = FrameParser.payloadLimit) { self.maxPayload = maxPayload }

    public mutating func feed(_ bytes: [UInt8]) -> [Frame] {
        var result: [Frame] = []
        for byte in bytes {
            // An unescaped start always resynchronizes, including after a bad escape.
            if byte == 0x3e {
                active = true; escaped = false; body.removeAll(keepingCapacity: true)
                continue
            }
            guard active else { continue }
            if escaped {
                guard (0x2c...0x2e).contains(byte) else { reset(); continue }
                body.append(byte | 0x10); escaped = false
            } else if byte == 0x3d {
                escaped = true
            } else if byte == 0x3c {
                if let frame = decode() { result.append(frame) }
                reset()
            } else {
                body.append(byte)
            }
            if body.count > maxPayload + 7 { reset() }
        }
        return result
    }

    private mutating func reset() {
        active = false; escaped = false; body.removeAll(keepingCapacity: true)
    }

    private func decode() -> Frame? {
        guard body.count >= 7, body[1] <= 1 else { return nil }
        let length = body[2..<6].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= maxPayload, body.count == Int(length) + 7,
              body.dropLast().reduce(UInt8(0), &+) == body.last else { return nil }
        guard body[0] != 1 || length == 0 else { return nil }
        return Frame(dataType: body[0], sequence: body[1], payload: Array(body[6..<body.count - 1]))
    }
}
