import Foundation

struct HeadphoneCandidate: Equatable {
    let id: String
    let name: String
    let isConnected: Bool
}

struct AudioOutputIdentity {
    let uid: String?
    let name: String?
}

/// Selects a control target without inferring Sony protocol features from names.
/// A display-name match is only a fallback for identifying the system output.
enum AutoConnectionPolicy {
    static func targetID(candidates: [HeadphoneCandidate], savedID: String?, output: AudioOutputIdentity?) -> String? {
        let connected = candidates.filter(\.isConnected)
        if let uid = output?.uid {
            let matches = connected.filter { candidate in
                if candidate.id == uid { return true }
                guard let deviceAddress = addressPrefix(candidate.id), let outputAddress = addressPrefix(uid) else { return false }
                return deviceAddress == outputAddress
            }
            if matches.count == 1 { return matches[0].id }
        }
        if let name = output?.name, !name.isEmpty {
            let matches = connected.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if matches.count == 1 { return matches[0].id }
        }
        if let savedID, connected.contains(where: { $0.id == savedID }) { return savedID }
        return connected.count == 1 ? connected[0].id : nil
    }

    private static func addressPrefix(_ value: String) -> String? {
        let prefix = String(value.prefix(17)).replacingOccurrences(of: "-", with: ":").uppercased()
        let bytes = Array(prefix.utf8)
        guard bytes.count == 17 else { return nil }
        for (index, byte) in bytes.enumerated() {
            if index % 3 == 2 {
                guard byte == 58 else { return nil }
            } else if !(48...57).contains(byte) && !(65...70).contains(byte) { return nil }
        }
        return prefix
    }
}
