import SwiftUI

extension AIMode {
    var title: String {
        switch self {
        case .onDevice: String(localized: "Apple on-device", table: "Account")
        case .local: String(localized: "Local model", table: "Account")
        case .byok: String(localized: "Your API key (BYOK)", table: "Account")
        case .hybrid: String(localized: "Hybrid", table: "Account")
        }
    }

    /// Short badge for the Account row.
    var badge: String {
        switch self {
        case .onDevice: String(localized: "On-device", table: "Account")
        case .local: String(localized: "Local", table: "Account")
        case .byok: "BYOK"
        case .hybrid: String(localized: "Hybrid", table: "Account")
        }
    }

    var summary: String {
        switch self {
        case .onDevice: String(localized: "Apple Intelligence on this iPhone. Private, offline, free.", table: "Account")
        case .local: String(localized: "An open model (Gemma, Qwen…) you download. Private, offline, free.", table: "Account")
        case .byok: String(localized: "A cloud model with your own key. Smartest, needs internet.", table: "Account")
        case .hybrid: String(localized: "Transactions are read on this iPhone; advice and reports use your cloud key.", table: "Account")
        }
    }

    /// What leaves the phone in this mode (spec §6.2).
    var cloudNote: String {
        switch self {
        case .onDevice, .local:
            String(localized: "Nothing is sent to the cloud. Moonee has no server.", table: "Account")
        case .byok:
            String(localized: "Sent to your provider: what you type to Moonee, the chat so far, and the numbers Moonee looks up to answer (totals, jar balances, matching transactions). Sent with your key, straight from this iPhone; Moonee has no server.", table: "Account")
        case .hybrid:
            String(localized: "Typed transactions stay on this iPhone. For questions, advice and reports, your message, the chat so far and the numbers Moonee looks up are sent to your provider with your key. Moonee has no server.", table: "Account")
        }
    }
}

extension CloudProvider {
    var title: String {
        switch self {
        case .openAICompatible: "OpenRouter"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        }
    }
}

private extension Skill {
    var title: String {
        switch id {
        case Skill.transactionParser.id: String(localized: "Read transactions", table: "Account")
        case Skill.jarBudgeting.id: String(localized: "Jar budgeting", table: "Account")
        case Skill.closeManagement.id: String(localized: "Month-end close", table: "Account")
        default: String(localized: "Spending coach", table: "Account")
        }
    }

    var summary: String {
        switch id {
        case Skill.transactionParser.id: String(localized: "Off: only Moonee's built-in rules read what you type.", table: "Account")
        case Skill.jarBudgeting.id: String(localized: "Splitting income and balancing jars.", table: "Account")
        case Skill.closeManagement.id: String(localized: "Month-end checklist and report.", table: "Account")
        default: String(localized: "Questions about your spending, with tips.", table: "Account")
        }
    }
}

/// Account → AI assistant (spec §6.2, §9.1).
struct AISettingsView: View {
    @AppStorage(LLMSettings.modeKey) private var mode = LLMSettings.mode
    @AppStorage(LLMSettings.cloudKey) private var provider = LLMSettings.cloudProvider
    @AppStorage(LLMSettings.baseURLKey) private var baseURL = LLMSettings.defaultBaseURL
    @AppStorage(LLMSettings.customPromptKey) private var customPrompt = ""
    @State private var skillsOff = LLMSettings.skillsOff
    @State private var apiKey = ""
    @State private var model = ""
    @State private var testResult: String?
    @State private var testing = false

    private var usesCloud: Bool { mode == .byok || mode == .hybrid }

    var body: some View {
        Form {
            Section {
                ForEach(AIMode.allCases, id: \.self) { m in
                    Button { mode = m } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.title).foregroundStyle(Color.ink)
                                Text(m.summary).font(.caption).foregroundStyle(Color.inkSecondary)
                            }
                            Spacer()
                            if mode == m { Image(systemName: "checkmark").foregroundStyle(Color.brandDeep).fontWeight(.semibold) }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(mode == m ? .isSelected : [])
                }
            } header: {
                Text("AI mode", tableName: "Account")
            } footer: {
                if mode == .onDevice || mode == .hybrid { Text(LLMSettings.appleStatus) }
            }

            if mode == .local || mode == .hybrid {
                Section {
                    // ponytail: S9 replaces this destination with its local-model manager.
                    NavigationLink {
                        ContentUnavailableView(String(localized: "Local models", table: "Account"), systemImage: "arrow.down.circle",
                                               description: Text("Downloadable models are coming soon.", tableName: "Account"))
                            .background(MooneeBackground())
                    } label: {
                        Label { Text("Local models", tableName: "Account") } icon: { Image(systemName: "cpu") }
                    }
                }
            }

            if usesCloud {
                Section {
                    LabeledContent(String(localized: "Provider", table: "Account")) {
                        Picker(String(localized: "Provider", table: "Account"), selection: $provider) {
                            ForEach(CloudProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    SecureField(String(localized: "API key", table: "Account"), text: $apiKey)
                        .onChange(of: apiKey) { LLMSettings.setAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: provider) }
                    LabeledContent(String(localized: "Model", table: "Account")) {
                        TextField(provider.defaultModel, text: $model).multilineTextAlignment(.trailing)
                            .onChange(of: model) { UserDefaults.standard.set(model.trimmingCharacters(in: .whitespaces), forKey: provider.modelKey) }
                    }
                    if provider == .openAICompatible {
                        LabeledContent(String(localized: "Base URL", table: "Account")) {
                            TextField(LLMSettings.defaultBaseURL, text: $baseURL).multilineTextAlignment(.trailing).keyboardType(.URL)
                        }
                    }
                } header: {
                    Text("Your API key", tableName: "Account")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The key is kept in this iPhone's Keychain. You pay your provider directly.", tableName: "Account")
                        if provider == .openAICompatible {
                            Text("Change the base URL to use any OpenAI-compatible server.", tableName: "Account")
                        }
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }

            Section {
                Label { Text(mode.cloudNote) } icon: { Image(systemName: usesCloud ? "icloud.and.arrow.up" : "lock.shield") }
                    .font(.footnote)
                Button(action: test) {
                    HStack {
                        Text("Test connection", tableName: "Account")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing)
                if let testResult { Text(testResult).font(.footnote) }
            } header: {
                Text("What leaves this iPhone", tableName: "Account")
            }

            Section {
                ForEach(Skill.all, id: \.self) { skill in
                    Toggle(isOn: Binding(get: { !skillsOff.contains(skill.id) }, set: { on in
                        if on { skillsOff.remove(skill.id) } else { skillsOff.insert(skill.id) }
                        UserDefaults.standard.set(skillsOff.sorted(), forKey: LLMSettings.skillsOffKey)
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.title)
                            Text(skill.summary).font(.caption).foregroundStyle(Color.inkSecondary)
                        }
                    }
                }
            } header: {
                Text("Skills", tableName: "Account")
            } footer: {
                Text("A skill that is off never calls a model: Moonee shows the plain numbers instead.", tableName: "Account")
            }

            Section {
                NavigationLink {
                    Form {
                        Section {
                            TextEditor(text: $customPrompt).frame(minHeight: 200)
                        } footer: {
                            Text("Added to every answer, e.g. “Keep answers under three sentences.” Numbers are always computed by the app.", tableName: "Account")
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(MooneeBackground())
                    .navigationTitle(Text("Custom instructions", tableName: "Account"))
                } label: {
                    LabeledContent {
                        Text(customPrompt.isEmpty ? String(localized: "None", table: "Account") : String(localized: "On", table: "Account"))
                    } label: {
                        Text("Custom instructions", tableName: "Account")
                    }
                }
            } header: {
                Text("Advanced", tableName: "Account")
            }
        }
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .navigationTitle(Text("AI assistant", tableName: "Account"))
        .onAppear(perform: loadProvider)
        .onChange(of: provider) { loadProvider() }
        .onChange(of: mode) { testResult = nil }
    }

    private func loadProvider() {
        apiKey = LLMSettings.apiKey(for: provider) ?? ""
        model = UserDefaults.standard.string(forKey: provider.modelKey) ?? ""
        testResult = nil
    }

    private func test() {
        guard let llm = LLMSettings.router().candidates(for: .quickAnswer).first else {
            testResult = "❌ " + String(localized: "No model is set up for this mode yet.", table: "Account")
            return
        }
        testing = true
        testResult = nil
        Task {
            do {
                let reply = try await llm.complete(system: "Reply with exactly one word.", user: "Say OK.")
                testResult = "✅ " + String(localized: "Connected: \(String(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)))", table: "Account")
            } catch {
                testResult = "❌ \(error.localizedDescription)"
            }
            testing = false
        }
    }
}
