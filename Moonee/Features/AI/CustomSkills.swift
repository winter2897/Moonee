import Foundation
import SwiftData

/// One stored skill text: a user's own skill, or the user's override of a built-in skill's text in one language.
/// CloudKit-ready (defaults everywhere, no unique constraints); registered in `Schema.mooneeModels`.
@Model final class SkillStore {
    /// User skills: "user.<slug>". Overrides: the built-in id ("jar-budgeting").
    var key: String = ""
    var isOverride: Bool = false
    /// Overrides: the language whose text they replace. User skills: "" (their text is used whatever the UI language).
    var language: String = ""
    var name: String = ""
    var summary: String = ""
    /// Comma-separated trigger words.
    var triggers: String = ""
    /// Comma-separated tool names.
    var tools: String = ""
    var instructions: String = ""
    var shortInstructions: String = ""
    var enabled: Bool = true
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(key: String, isOverride: Bool = false, language: String = "") {
        self.key = key
        self.isOverride = isOverride
        self.language = language
    }

    var draft: SkillDraft {
        SkillDraft(name: name, summary: summary, triggers: SkillDraft.list(triggers), tools: SkillDraft.list(tools),
                   instructions: instructions, shortInstructions: shortInstructions)
    }

    func apply(_ d: SkillDraft) {
        name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        summary = d.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        triggers = d.triggers.joined(separator: ", ")
        tools = d.tools.joined(separator: ", ")
        instructions = d.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        shortInstructions = d.shortInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedAt = .now
    }

    var skill: Skill {
        Skill(id: key, tools: SkillDraft.list(tools), job: .advice, title: name, triggers: SkillDraft.list(triggers),
              text: SkillText(full: instructions, short: shortInstructions))
    }
}

/// A user skill being imported or edited.
struct SkillDraft: Equatable, Sendable {
    var name = ""
    var summary = ""
    var triggers: [String] = []
    var tools: [String] = []
    var instructions = ""
    var shortInstructions = ""

    static func list(_ s: String) -> [String] {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }.filter { !$0.isEmpty }
    }
}

enum SkillError: LocalizedError, Equatable {
    case tooLarge, noFrontMatter, missingName, noTriggers, noInstructions, unknownTools([String]), containsSecret

    var errorDescription: String? {
        switch self {
        case .tooLarge: String(localized: "The skill is too long (20 KB at most).", table: "AI")
        case .noFrontMatter: String(localized: "The file needs a front matter block between --- lines with name, description, triggers and tools.", table: "AI")
        case .missingName: String(localized: "Give the skill a name.", table: "AI")
        case .noTriggers: String(localized: "Add at least one trigger word, or Moonee will never use the skill.", table: "AI")
        case .noInstructions: String(localized: "Write the skill's instructions.", table: "AI")
        case .unknownTools(let names): String(localized: "Unknown tools: \(names.joined(separator: ", ")).", table: "AI")
        case .containsSecret: String(localized: "Remove the API key, password or token from the skill: it would be sent to the AI.", table: "AI")
        }
    }
}

/// The `.md` skill format: front matter, then the instructions, then optionally `<!-- short -->` and a short version.
///
///     ---
///     name: Tax helper
///     description: Questions about personal income tax
///     triggers: thuế, tax
///     tools: spendingSummary, listTransactions
///     ---
///     Full instructions…
///     <!-- short -->
///     Short instructions…
enum SkillFile {
    static let maxBytes = 20_000

    static func parse(_ text: String) throws -> SkillDraft {
        guard text.utf8.count <= maxBytes else { throw SkillError.tooLarge }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { throw SkillError.noFrontMatter }

        var d = SkillDraft()
        var listKey: String? // YAML block lists: "triggers:" then "- word" lines
        for line in lines[1..<end] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- "), let k = listKey {
                let item = String(t.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if k == "triggers" { d.triggers.append(item) } else if k == "tools" { d.tools.append(item) }
                continue
            }
            guard let colon = t.firstIndex(of: ":") else { continue }
            let key = t[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = t[t.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            listKey = value.isEmpty ? key : nil
            switch key {
            case "name": d.name = value
            case "description": d.summary = value
            case "triggers": d.triggers += SkillDraft.list(value)
            case "tools": d.tools += SkillDraft.list(value)
            default: break
            }
        }
        let body = lines[(end + 1)...].joined(separator: "\n").components(separatedBy: "<!-- short -->")
        d.instructions = body[0].trimmingCharacters(in: .whitespacesAndNewlines)
        d.shortInstructions = body.count > 1 ? body[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        try validate(d)
        return d
    }

    static func validate(_ d: SkillDraft, knownTools: [String] = MooneeTools.allNames) throws {
        let all = [d.name, d.summary, d.instructions, d.shortInstructions] + d.triggers
        guard all.joined().utf8.count <= maxBytes else { throw SkillError.tooLarge }
        guard !d.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw SkillError.missingName }
        guard !d.triggers.isEmpty else { throw SkillError.noTriggers }
        guard !d.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SkillError.noInstructions }
        let unknown = d.tools.filter { !knownTools.contains($0) }
        guard unknown.isEmpty else { throw SkillError.unknownTools(unknown) }
        guard !all.contains(where: containsSecret) else { throw SkillError.containsSecret }
    }

    /// API keys (OpenAI/Anthropic/OpenRouter/DeepSeek `sk-…`, Google `AIza…`, Tavily, GitHub), bearer tokens,
    /// and "password: …" style lines. Prompts go to cloud models, so no secret may ride along.
    static func containsSecret(_ s: String) -> Bool {
        let patterns = [
            #"sk-[A-Za-z0-9_\-]{16,}"#, #"AIza[0-9A-Za-z_\-]{30,}"#, #"tvly-[A-Za-z0-9_\-]{10,}"#, #"gh[pousr]_[A-Za-z0-9]{30,}"#,
            #"(?i)bearer\s+[A-Za-z0-9._\-]{16,}"#,
            #"(?i)(api[ _-]?key|secret|password|passwd|mật khẩu|token)\s*[:=]\s*\S{8,}"#,
        ]
        return patterns.contains { s.range(of: $0, options: .regularExpression) != nil }
    }
}

/// The skills the router may pick: built-ins (with the user's overrides) plus the user's enabled skills.
struct SkillCatalog: Sendable {
    var userSkills: [Skill] = []
    /// Built-in id → the user's text for the current language.
    var overrides: [String: SkillText] = [:]

    static let builtIn = SkillCatalog()

    func resolved(_ s: Skill) -> Skill {
        guard s.text == nil, let o = overrides[s.id] else { return s }
        var r = s
        r.text = o
        return r
    }

    init(userSkills: [Skill] = [], overrides: [String: SkillText] = [:]) {
        (self.userSkills, self.overrides) = (userSkills, overrides)
    }

    init(records: [SkillStore], language: String) {
        userSkills = records.filter { !$0.isOverride && $0.enabled }.sorted { $0.createdAt < $1.createdAt }.map(\.skill)
        for r in records where r.isOverride && r.language == language {
            overrides[r.key] = SkillText(full: r.instructions, short: r.shortInstructions)
        }
    }

    /// From the store, for the chat: `Assistant(router:tools:catalog: SkillCatalog(context))`.
    init(_ context: ModelContext, language: String = Assistant.uiLanguage) {
        self.init(records: (try? context.fetch(FetchDescriptor<SkillStore>())) ?? [], language: language)
    }
}

extension SkillStore {
    /// Imports a `.md` skill file as a new, enabled user skill.
    @discardableResult
    static func importFile(_ text: String, into context: ModelContext) throws -> SkillStore {
        try create(SkillFile.parse(text), in: context)
    }

    @discardableResult
    static func create(_ d: SkillDraft, in context: ModelContext) throws -> SkillStore {
        try SkillFile.validate(d)
        let taken = Set(((try? context.fetch(FetchDescriptor<SkillStore>())) ?? []).map(\.key))
        let base = "user." + slug(d.name)
        var key = base, n = 2
        while taken.contains(key) || Skill.all.contains(where: { $0.id == key }) { key = "\(base)-\(n)"; n += 1 }
        let s = SkillStore(key: key)
        s.apply(d)
        context.insert(s)
        return s
    }

    func update(_ d: SkillDraft) throws {
        try SkillFile.validate(d)
        apply(d)
    }

    /// Saves the user's text for a built-in skill (this language only). Same secret and size checks as user skills.
    @discardableResult
    static func override(_ builtIn: Skill, text: SkillText, language: String, in context: ModelContext) throws -> SkillStore {
        guard !text.full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SkillError.noInstructions }
        guard (text.full + text.short).utf8.count <= SkillFile.maxBytes else { throw SkillError.tooLarge }
        guard !SkillFile.containsSecret(text.full + "\n" + text.short) else { throw SkillError.containsSecret }
        let s = overrideRecord(builtIn.id, language: language, in: context) ?? {
            let new = SkillStore(key: builtIn.id, isOverride: true, language: language)
            context.insert(new)
            return new
        }()
        (s.instructions, s.shortInstructions, s.updatedAt) = (text.full, text.short, .now)
        return s
    }

    /// "Reset to default": drops the user's text, so the bundled file is used again.
    static func resetToDefault(_ builtInID: String, language: String, in context: ModelContext) {
        if let s = overrideRecord(builtInID, language: language, in: context) { context.delete(s) }
    }

    static func overrideRecord(_ id: String, language: String, in context: ModelContext) -> SkillStore? {
        let all = (try? context.fetch(FetchDescriptor<SkillStore>(predicate: #Predicate { $0.isOverride && $0.key == id }))) ?? []
        return all.first { $0.language == language }
    }

    static func slug(_ name: String) -> String {
        let folded = Token.fold(name.lowercased())
        let s = folded.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return s.isEmpty ? "skill" : String(s.prefix(40))
    }
}
