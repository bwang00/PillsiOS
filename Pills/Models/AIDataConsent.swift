import Foundation

/// Whether the user has been asked for, and given, permission to share their
/// messages with the third-party AI services (guideline 5.1.1(i) / 5.1.2(i)).
enum AIDataConsentState: String, Codable, Sendable {
    case notAsked
    case granted
    case denied
}

protocol AIDataConsentStore: Sendable {
    func currentState() -> AIDataConsentState
    func save(_ state: AIDataConsentState)
}

struct UserDefaultsAIDataConsentStore: AIDataConsentStore {
    static let key = "aiDataConsentState"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func currentState() -> AIDataConsentState {
        guard let raw = defaults.string(forKey: Self.key) else { return .notAsked }
        return AIDataConsentState(rawValue: raw) ?? .notAsked
    }

    func save(_ state: AIDataConsentState) {
        defaults.set(state.rawValue, forKey: Self.key)
    }
}

final class InMemoryAIDataConsentStore: AIDataConsentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: AIDataConsentState

    init(initial: AIDataConsentState = .notAsked) {
        self.state = initial
    }

    func currentState() -> AIDataConsentState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func save(_ newState: AIDataConsentState) {
        lock.lock()
        state = newState
        lock.unlock()
    }
}
