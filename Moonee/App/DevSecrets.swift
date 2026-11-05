import Foundation

/// Debug + Simulator only: reads `<repo>/.env` straight off the Mac's disk and moves the API key into
/// Keychain, so testers skip pasting it in the app. Release builds never contain this.
enum DevSecrets {
    static func load() {
        #if DEBUG && targetEnvironment(simulator)
        // #filePath = <repo>/Moonee/App/DevSecrets.swift
        let env = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".env")
        guard let text = try? String(contentsOf: env, encoding: .utf8) else { return }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[1].isEmpty { values[parts[0]] = parts[1].trimmingCharacters(in: .init(charactersIn: "\"'")) }
        }

        if let key = values["OPENROUTER_API_KEY"], LLMSettings.apiKey != key {
            LLMSettings.apiKey = key
        }
        #endif
    }
}
