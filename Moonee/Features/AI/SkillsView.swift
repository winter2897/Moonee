import SwiftData
import SwiftUI
import UniformTypeIdentifiers

extension Skill {
    /// Display name: the user's for their skills, a localized one for built-ins.
    var displayTitle: String {
        if let title { return title }
        return switch id {
        case Skill.transactionParser.id: String(localized: "Read transactions", table: "Account")
        case Skill.receiptReader.id: String(localized: "Read photos and receipts", table: "AI")
        case Skill.jarBudgeting.id: String(localized: "Jar budgeting", table: "Account")
        case Skill.closeManagement.id: String(localized: "Month-end close", table: "Account")
        case Skill.marketLookup.id: String(localized: "Market lookup", table: "AI")
        default: String(localized: "Spending coach", table: "Account")
        }
    }

    var displaySummary: String {
        switch id {
        case Skill.transactionParser.id: String(localized: "Off: only Moonee's built-in rules read what you type.", table: "Account")
        case Skill.receiptReader.id: String(localized: "Receipts, transfer screenshots, bills and statements. Off: only Moonee's built-in rules read them.", table: "AI")
        case Skill.jarBudgeting.id: String(localized: "Splitting income and balancing jars.", table: "Account")
        case Skill.closeManagement.id: String(localized: "Month-end checklist and report.", table: "Account")
        case Skill.marketLookup.id: String(localized: "Gold, exchange rates, crypto and news, with sources. Uses web search.", table: "AI")
        default: String(localized: "Questions about your spending, with tips.", table: "Account")
        }
    }
}

enum ToolInfo {
    static func title(_ name: String) -> String {
        switch name {
        case "spendingSummary": String(localized: "Spending summary", table: "AI")
        case "listTransactions": String(localized: "Recent transactions", table: "AI")
        case "jarBalances": String(localized: "Jar balances", table: "AI")
        case "splitIncome": String(localized: "Split an income", table: "AI")
        case "savingsPlan": String(localized: "Savings plan", table: "AI")
        case "monthClose": String(localized: "Month-end close", table: "Account")
        case "webSearch": String(localized: "Web search", table: "AI")
        case "marketPrice": String(localized: "Crypto prices", table: "AI")
        default: name
        }
    }
}

/// Account → AI assistant → Skills, also linked from the chat: built-in skills (on/off, edit text, reset)
/// and the user's own skills (new, import `.md`, edit, on/off, delete).
struct SkillsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SkillStore.createdAt) private var records: [SkillStore]
    @State private var skillsOff = LLMSettings.skillsOff
    @State private var importing = false
    @State private var creating = false
    @State private var error: String?
    private let language = Assistant.uiLanguage

    private var userSkills: [SkillStore] { records.filter { !$0.isOverride } }

    var body: some View {
        Form {
            Section {
                ForEach(Skill.all, id: \.self) { skill in
                    NavigationLink {
                        SkillEditorView(builtIn: skill, skillsOff: $skillsOff)
                    } label: {
                        row(skill.displayTitle, skill.displaySummary, on: !skillsOff.contains(skill.id),
                            edited: records.contains { $0.isOverride && $0.key == skill.id && $0.language == language })
                    }
                }
            } header: {
                Text("Built-in", tableName: "AI")
            } footer: {
                Text("A skill that is off never calls a model: Moonee shows the plain numbers instead.", tableName: "Account")
            }

            Section {
                ForEach(userSkills) { record in
                    NavigationLink {
                        SkillEditorView(record: record)
                    } label: {
                        row(record.name, record.summary, on: record.enabled, edited: false)
                    }
                }
                .onDelete { offsets in offsets.map { userSkills[$0] }.forEach(context.delete) }
                Button { creating = true } label: { Label { Text("New skill", tableName: "AI") } icon: { Image(systemName: "plus") } }
                Button { importing = true } label: {
                    Label { Text("Import a .md file", tableName: "AI") } icon: { Image(systemName: "square.and.arrow.down") }
                }
            } header: {
                Text("Your skills", tableName: "AI")
            } footer: {
                Text("Moonee uses your skill when a question contains one of its trigger words. Numbers still come from the app.", tableName: "AI")
            }
        }
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .navigationTitle(Text("Skills", tableName: "Account"))
        .navigationDestination(isPresented: $creating) { SkillEditorView(record: nil) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "md") ?? .plainText, .plainText]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try SkillStore.importFile(String(contentsOf: url, encoding: .utf8), into: context)
            } catch {
                self.error = error.localizedDescription
            }
        }
        .alert(String(localized: "Can't use this skill", table: "AI"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func row(_ title: String, _ summary: String, on: Bool, edited: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).font(.rowTitle).foregroundStyle(Color.ink)
                if edited { Text("Edited", tableName: "AI").font(.chip).foregroundStyle(Color.brandDeep) }
                if !on { Text("Off", tableName: "AI").font(.chip).foregroundStyle(Color.inkSecondary) }
            }
            if !summary.isEmpty { Text(summary).font(.secondaryText).foregroundStyle(Color.inkSecondary).lineLimit(2) }
        }
    }
}

/// Edits a user skill (all fields) or a built-in's text (with "Reset to default").
struct SkillEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    private let builtIn: Skill?
    private let record: SkillStore?
    private var skillsOff: Binding<Set<String>>?
    private let language = Assistant.uiLanguage

    @State private var draft = SkillDraft()
    @State private var enabled = true
    @State private var triggersText = ""
    @State private var error: String?
    @State private var loaded = false

    init(builtIn: Skill, skillsOff: Binding<Set<String>>) {
        (self.builtIn, self.record, self.skillsOff) = (builtIn, nil, skillsOff)
    }

    init(record: SkillStore?) {
        (self.builtIn, self.record, self.skillsOff) = (nil, record, nil)
    }

    private var hasOverride: Bool {
        builtIn.map { SkillStore.overrideRecord($0.id, language: language, in: context) != nil } ?? false
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) { Text("On", tableName: "Account") }
                if builtIn == nil {
                    TextField(text: $draft.name) { Text("Name", tableName: "AI") }
                    TextField(text: $draft.summary, axis: .vertical) { Text("What it is for", tableName: "AI") }
                    TextField(text: $triggersText, axis: .vertical) { Text("Trigger words, separated by commas", tableName: "AI") }
                        .textInputAutocapitalization(.never)
                } else if let builtIn {
                    Text(builtIn.displaySummary).font(.secondaryText).foregroundStyle(Color.inkSecondary)
                }
            }

            Section {
                ForEach(MooneeTools.allNames, id: \.self) { name in
                    if let builtIn {
                        if builtIn.tools.contains(name) { Label(ToolInfo.title(name), systemImage: "wrench.and.screwdriver") }
                    } else {
                        Toggle(ToolInfo.title(name), isOn: Binding(
                            get: { draft.tools.contains(name) },
                            set: { on in if on { draft.tools.append(name) } else { draft.tools.removeAll { $0 == name } } }))
                    }
                }
            } header: {
                Text("Tools it may use", tableName: "AI")
            }

            Section {
                TextEditor(text: $draft.instructions).frame(minHeight: 180).font(.bodyText)
            } header: {
                Text("Instructions", tableName: "AI")
            } footer: {
                Text("Written for the AI. Never put API keys or passwords here.", tableName: "AI")
            }

            Section {
                TextEditor(text: $draft.shortInstructions).frame(minHeight: 80).font(.bodyText)
            } header: {
                Text("Short version for on-device models", tableName: "AI")
            }

            if builtIn != nil, hasOverride {
                Section {
                    Button(role: .destructive, action: reset) { Text("Reset to default", tableName: "AI") }
                }
            }
            if let record {
                Section {
                    Button(role: .destructive) {
                        context.delete(record)
                        dismiss()
                    } label: { Text("Delete skill", tableName: "AI") }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .navigationTitle(builtIn?.displayTitle ?? (record == nil ? String(localized: "New skill", table: "AI") : record!.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button(action: save) { Text("Save", tableName: "AI") } }
        }
        .onAppear(perform: load)
        .alert(String(localized: "Can't use this skill", table: "AI"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let builtIn {
            let text = SkillStore.overrideRecord(builtIn.id, language: language, in: context)
                .map { SkillText(full: $0.instructions, short: $0.shortInstructions) } ?? Skill.bundled(builtIn.id, language: language)
            (draft.instructions, draft.shortInstructions) = (text.full, text.short)
            enabled = !(skillsOff?.wrappedValue.contains(builtIn.id) ?? false)
        } else if let record {
            draft = record.draft
            enabled = record.enabled
        }
        triggersText = draft.triggers.joined(separator: ", ")
    }

    private func save() {
        do {
            if let builtIn {
                var off = skillsOff?.wrappedValue ?? []
                if enabled { off.remove(builtIn.id) } else { off.insert(builtIn.id) }
                skillsOff?.wrappedValue = off
                UserDefaults.standard.set(off.sorted(), forKey: LLMSettings.skillsOffKey)
                let bundled = Skill.bundled(builtIn.id, language: language)
                let text = SkillText(full: draft.instructions, short: draft.shortInstructions)
                if text.full.trimmingCharacters(in: .whitespacesAndNewlines) != bundled.full || text.short.trimmingCharacters(in: .whitespacesAndNewlines) != bundled.short {
                    try SkillStore.override(builtIn, text: text, language: language, in: context)
                }
            } else {
                draft.triggers = SkillDraft.list(triggersText)
                let s = try record.map { try $0.update(draft); return $0 } ?? SkillStore.create(draft, in: context)
                s.enabled = enabled
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reset() {
        guard let builtIn else { return }
        SkillStore.resetToDefault(builtIn.id, language: language, in: context)
        let text = Skill.bundled(builtIn.id, language: language)
        (draft.instructions, draft.shortInstructions) = (text.full, text.short)
    }
}

#Preview {
    NavigationStack { SkillsView() }.modelContainer(for: Schema.mooneeModels, inMemory: true)
}
