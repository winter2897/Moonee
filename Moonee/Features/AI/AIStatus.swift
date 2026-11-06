import Foundation

/// Why Moonee could not answer the way the user chose. Thrown by small models, shown as one friendly chat line.
enum AINotice: Error, Equatable, Sendable {
    /// The prompt didn't fit the model's context window, even trimmed.
    case tooLong
    case failed

    /// An `AINotice` stays itself; any other error → `.failed`.
    init(_ error: any Error) {
        self = error as? AINotice ?? .failed
    }

    /// `answeredByModel`: another model stepped in; else the rules / the app's own numbers did.
    func text(answeredByModel: Bool) -> String {
        let reason: String = switch self {
        case .tooLong: String(localized: "That was a bit long for the on-device model.", table: "AI")
        case .failed: String(localized: "The on-device model hit a snag.", table: "AI")
        }
        let fallback = answeredByModel
            ? String(localized: "Moonee asked your cloud model instead.", table: "AI")
            : String(localized: "Moonee used the app's own numbers for now.", table: "AI")
        return reason + " " + fallback
    }
}
