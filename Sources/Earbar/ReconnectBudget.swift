/// A retry budget belongs to one interruption, not the app's entire lifetime.
struct ReconnectBudget {
    private(set) var currentAttempt = 0
    mutating func nextAttempt() -> Int? {
        guard currentAttempt < 3 else { return nil }
        currentAttempt += 1
        return currentAttempt
    }
    mutating func reset() { currentAttempt = 0 }
    mutating func connectionEstablished() { reset() }
}
