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

    /// What leaves the phone in this mode (spec §6.2), naming the BYOK provider.
    func cloudNote(_ provider: String) -> String {
        switch self {
        case .onDevice, .local:
            String(localized: "Nothing is sent to the cloud. Moonee has no server.", table: "Account")
        case .byok:
            String(localized: "Sent to \(provider): what you type to Moonee, the chat so far, and the numbers Moonee looks up to answer (totals, jar balances, matching transactions). Sent with your key, straight from this iPhone; Moonee has no server.", table: "Account")
        case .hybrid:
            String(localized: "Typed transactions stay on this iPhone. For questions, advice and reports, your message, the chat so far and the numbers Moonee looks up are sent to \(provider) with your key. Moonee has no server.", table: "Account")
        }
    }
}

extension CloudProvider {
    var title: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .deepSeek: "DeepSeek"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .custom: String(localized: "Custom (OpenAI-compatible)", table: "Account")
        }
    }
}

/// Account → AI assistant (spec §6.2, §9.1).
struct AISettingsView: View {
    @AppStorage(LLMSettings.modeKey) private var mode = LLMSettings.mode
    @AppStorage(LLMSettings.cloudKey) private var provider = LLMSettings.cloudProvider
    @AppStorage(LLMSettings.baseURLKey) private var customURL = ""
    @AppStorage(LLMSettings.customPromptKey) private var customPrompt = ""
    @State private var searchProvider = SearchSettings.keyProvider
    @State private var webSearchOn = LLMSettings.webSearch // redraws the toggle
    @State private var searchKey = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var keyCheck: KeyCheck = .idle

    enum KeyCheck: Equatable { case idle, checking, ok(Int), failed(String) }

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
                if mode == .onDevice || mode == .hybrid {
                    let apple = AppleStatus.current()
                    Label(apple.text, systemImage: apple.canRun ? "checkmark.circle" : "exclamationmark.circle")
                }
            }

            if mode == .local || mode == .hybrid {
                Section {
                    NavigationLink {
                        LocalModelsView()
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
                    if provider == .custom {
                        LabeledContent(String(localized: "Base URL", table: "Account")) {
                            TextField(text: $customURL, prompt: Text(verbatim: "https://…/v1")) { Text("Base URL", tableName: "Account") }
                                .multilineTextAlignment(.trailing).keyboardType(.URL)
                        }
                    }
                    SecureField(String(localized: "API key", table: "Account"), text: $apiKey)
                        .onChange(of: apiKey) {
                            LLMSettings.setAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: provider)
                            keyCheck = .idle
                        }
                    if !apiKey.isEmpty {
                        Button(action: checkKey) {
                            HStack {
                                Text("Test key", tableName: "Account")
                                Spacer()
                                if keyCheck == .checking { ProgressView() }
                            }
                        }
                        .disabled(keyCheck == .checking || LLMSettings.baseURL(provider).isEmpty)
                        switch keyCheck {
                        case .ok(let n):
                            Label { Text("Key works. \(n) models available.", tableName: "Account") } icon: { Image(systemName: "checkmark.circle.fill") }
                                .font(.footnote).foregroundStyle(Color.brandDeep)
                        case .failed(let message):
                            Label(message, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Color.danger)
                        default: EmptyView()
                        }
                    }
                    NavigationLink {
                        ModelPickerView(provider: provider, baseURL: LLMSettings.baseURL(provider), apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                        selection: $model)
                    } label: {
                        LabeledContent(String(localized: "Model", table: "Account")) {
                            Text(model.isEmpty ? provider.defaultModel : model).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .onChange(of: model) { UserDefaults.standard.set(model, forKey: provider.modelKey) }
                } header: {
                    Text("Your API key", tableName: "Account")
                } footer: {
                    Text("The key is kept in this iPhone's Keychain. You pay your provider directly.", tableName: "Account")
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }

            Section {
                Label { Text(mode.cloudNote(provider.title)) } icon: { Image(systemName: usesCloud ? "icloud.and.arrow.up" : "lock.shield") }
                    .font(.footnote)
                Label { Text(SearchSettings.note) } icon: { Image(systemName: "magnifyingglass") }
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
                Toggle(isOn: Binding(get: { LLMSettings.webSearch }, set: { LLMSettings.webSearch = $0; webSearchOn = $0 })) {
                    Text("Web search", tableName: "AI")
                }
                Picker(selection: $searchProvider) {
                    Text("Off", tableName: "AI").tag(SearchKeyProvider?.none)
                    ForEach(SearchKeyProvider.allCases, id: \.self) { Text(verbatim: $0.title).tag(SearchKeyProvider?.some($0)) }
                } label: {
                    Text("Search key", tableName: "AI")
                }
                .onChange(of: searchProvider) {
                    SearchSettings.keyProvider = searchProvider
                    searchKey = searchProvider.flatMap(SearchSettings.key) ?? ""
                }
                if let p = searchProvider {
                    SecureField(String(localized: "\(p.title) API key", table: "AI"), text: $searchKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: searchKey) { SearchSettings.setKey(searchKey.trimmingCharacters(in: .whitespacesAndNewlines), for: p) }
                }
            } header: {
                Text("Web search", tableName: "AI")
            } footer: {
                // Redrawn by the toggle, the key picker and the key field (they are all state here).
                let _ = (webSearchOn, searchProvider, searchKey, mode, provider)
                Text(SearchSettings.route)
            }

            Section {
                NavigationLink {
                    SkillsView()
                } label: {
                    LabeledContent {
                        Text("\(Skill.all.count - LLMSettings.skillsOff.count) on", tableName: "AI")
                    } label: {
                        Text("Skills", tableName: "Account")
                    }
                }
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
        searchKey = searchProvider.flatMap(SearchSettings.key) ?? ""
        apiKey = LLMSettings.apiKey(for: provider) ?? ""
        model = UserDefaults.standard.string(forKey: provider.modelKey) ?? ""
        testResult = nil
        keyCheck = .idle
    }

    /// Loads the model list with the typed key: proves the key works and fills the picker's cache.
    private func checkKey() {
        keyCheck = .checking
        let (p, key, base) = (provider, apiKey.trimmingCharacters(in: .whitespacesAndNewlines), LLMSettings.baseURL(provider))
        Task {
            do {
                let list = try await LLMSettings.client(p, key: key, model: "", baseURL: base).listModels()
                try? ModelCache().save(list, for: p, baseURL: base)
                keyCheck = .ok(list.count)
            } catch {
                keyCheck = .failed(ModelPickerView.message(for: error))
            }
        }
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
