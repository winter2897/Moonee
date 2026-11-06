import Foundation
import FoundationModels

/// Whether Apple Intelligence can answer on this iPhone, and in which language (AI settings + chat notices).
enum AppleStatus: Equatable, Sendable {
    case ready
    /// Runs, but not in the app's language: Moonee answers in English.
    case languageUnsupported
    case notEligible, notEnabled, downloading, unavailable

    init(_ availability: SystemLanguageModel.Availability, supportsLanguage: Bool) {
        switch availability {
        case .available: self = supportsLanguage ? .ready : .languageUnsupported
        case .unavailable(.deviceNotEligible): self = .notEligible
        case .unavailable(.appleIntelligenceNotEnabled): self = .notEnabled
        case .unavailable(.modelNotReady): self = .downloading
        case .unavailable: self = .unavailable
        }
    }

    static func current(language: String = Assistant.uiLanguage) -> AppleStatus {
        let m = SystemLanguageModel.default
        return AppleStatus(m.availability, supportsLanguage: m.supportsLocale(Locale(identifier: language)))
    }

    var canRun: Bool { self == .ready || self == .languageUnsupported }

    var text: String {
        switch self {
        case .ready: String(localized: "Ready (Apple Intelligence, managed by iOS)", table: "Account")
        case .languageUnsupported: String(localized: "Ready, but Apple Intelligence doesn't speak your language yet: Moonee answers in English", table: "AI")
        case .notEligible: String(localized: "This iPhone does not support Apple Intelligence", table: "Account")
        case .notEnabled: String(localized: "Turn on Apple Intelligence in Settings", table: "Account")
        case .downloading: String(localized: "iOS is still downloading the model, try again later", table: "Account")
        case .unavailable: String(localized: "The on-device model is not ready", table: "Account")
        }
    }
}

/// Why Moonee could not answer the way the user chose. Thrown by small models, shown as one friendly chat line.
enum AINotice: Error, Equatable, Sendable {
    /// On-device mode, but Apple Intelligence can't run.
    case appleUnavailable(AppleStatus)
    /// Apple answered, in English (it doesn't speak the app's language).
    case answeredInEnglish
    case languageUnsupported
    /// The prompt didn't fit the model's context window, even trimmed.
    case tooLong
    /// Apple's safety guardrails stopped the answer.
    case blocked
    case failed

    /// Foundation Models errors (iOS 27 `LanguageModelError`, iOS 26 `GenerationError`) as a notice; others → `.failed`.
    init(_ error: any Error) {
        if let e = error as? AINotice {
            self = e
        } else if #available(iOS 27.0, macOS 27.0, *), let e = error as? LanguageModelError {
            switch e {
            case .contextSizeExceeded: self = .tooLong
            case .guardrailViolation, .refusal: self = .blocked
            case .unsupportedLanguageOrLocale: self = .languageUnsupported
            default: self = .failed
            }
        } else if let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .exceededContextWindowSize: self = .tooLong
            case .guardrailViolation, .refusal: self = .blocked
            case .unsupportedLanguageOrLocale: self = .languageUnsupported
            case .assetsUnavailable: self = .appleUnavailable(.downloading)
            default: self = .failed
            }
        } else {
            self = .failed
        }
    }

    /// `answeredByModel`: another model stepped in; else the rules / the app's own numbers did.
    func text(answeredByModel: Bool) -> String {
        if self == .answeredInEnglish {
            return String(localized: "Apple Intelligence doesn't speak your language on this iPhone yet, so Moonee replied in English.", table: "AI")
        }
        let reason: String = switch self {
        case .answeredInEnglish: ""
        case .appleUnavailable(let s): s.text + "."
        case .languageUnsupported: String(localized: "Apple Intelligence doesn't support this language yet.", table: "AI")
        case .tooLong: String(localized: "That was a bit long for the on-device model.", table: "AI")
        case .blocked: String(localized: "Apple Intelligence wouldn't answer that one.", table: "AI")
        case .failed: String(localized: "The on-device model hit a snag.", table: "AI")
        }
        let fallback = answeredByModel
            ? String(localized: "Moonee asked your other on-device model instead.", table: "AI")
            : String(localized: "Moonee used the app's own numbers for now.", table: "AI")
        return reason + " " + fallback
    }
}
