import Foundation
import SwiftUI

// ponytail: stand-ins for S3's engine API (reasoning effort, skills screen, web search) so the chat UI builds before
// S3's PR lands. Delete this file when it does; the names below are the contract S0 gave both sessions.

enum ReasoningEffort: String, CaseIterable, Codable, Sendable {
    case low, medium, high, higher, max
}

extension LLMSettings {
    static let effortKey = "ai.effort"
    static let webSearchKey = "ai.webSearch"

    static var effort: ReasoningEffort {
        get { ReasoningEffort(rawValue: UserDefaults.standard.string(forKey: effortKey) ?? "") ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: effortKey) }
    }

    static var webSearch: Bool {
        get { UserDefaults.standard.bool(forKey: webSearchKey) }
        set { UserDefaults.standard.set(newValue, forKey: webSearchKey) }
    }
}

/// Efforts a cloud model accepts; empty = the model has no effort setting.
func supportedEfforts(provider: CloudProvider, model: String) -> [ReasoningEffort] {
    provider == .custom ? [] : ReasoningEffort.allCases
}

/// A page a web-search answer came from.
struct WebSource: Codable, Hashable, Sendable {
    var title: String
    var url: URL
    var site: String
    var date: Date?
}

/// S3's skills screen; for now the AI settings, where skills are switched on and off.
struct SkillsView: View {
    var body: some View { AISettingsView() }
}
