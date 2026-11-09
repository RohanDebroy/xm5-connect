import TandemCore

/// Keep the last confirmed selection visible during a device transition.
/// Commands and availability still use live state, never this display snapshot.
struct ListeningPresentation: Equatable {
    private(set) var confirmed: ListeningStatus?

    mutating func update(_ status: ListeningStatus?) {
        guard let status else { confirmed = nil; return }
        if !status.isChanging { confirmed = status }
        else if confirmed?.profile != status.profile { confirmed = nil }
    }
}
