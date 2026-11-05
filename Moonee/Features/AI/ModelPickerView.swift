import SwiftUI

/// AI settings → Model: the models this key can use (cached per provider), searchable, with OpenRouter's
/// context/price/capabilities, plus a typed-ID fallback for servers that don't list models.
struct ModelPickerView: View {
    let provider: CloudProvider
    let baseURL: String
    let apiKey: String
    @Binding var selection: String

    @Environment(\.dismiss) private var dismiss
    @State private var models: [CloudModel] = []
    @State private var fetched: Date?
    @State private var search = ""
    @State private var typed = ""
    @State private var loading = false
    @State private var error: String?

    private var filtered: [CloudModel] {
        guard !search.isEmpty else { return models }
        return models.filter { $0.id.localizedCaseInsensitiveContains(search) || ($0.name ?? "").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField(String(localized: "Type a model ID", table: "Account"), text: $typed)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit(useTyped)
                    Button(String(localized: "Use", table: "Account"), action: useTyped)
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("For servers that don't list their models.", tableName: "Account")
            }

            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Color.danger).font(.footnote) }
            }

            Section {
                if loading && models.isEmpty {
                    HStack { ProgressView(); Text("Loading models…", tableName: "Account") }
                } else if models.isEmpty {
                    Text("No list yet. Pull to refresh, or type a model ID.", tableName: "Account").foregroundStyle(Color.inkSecondary)
                }
                ForEach(filtered) { model in
                    Button { selection = model.id; dismiss() } label: { ModelRow(model: model, selected: model.id == selection) }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.id == selection ? .isSelected : [])
                }
            } header: {
                if !models.isEmpty {
                    HStack {
                        Text("\(models.count) models", tableName: "Account")
                        Spacer()
                        if let fetched { Text(fetched, format: .relative(presentation: .named)) }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: Text("Search models", tableName: "Account"))
        .refreshable { await refresh() }
        .toolbar {
            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel(Text("Refresh", tableName: "Account"))
                .disabled(loading)
        }
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .navigationTitle(Text("Model", tableName: "Account"))
        .task {
            if let cached = ModelCache().load(provider, baseURL: baseURL) {
                (models, fetched) = (cached.models, cached.fetched)
            } else {
                await refresh()
            }
        }
    }

    private func useTyped() {
        let id = typed.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        selection = id
        dismiss()
    }

    private func refresh() async {
        loading = true
        defer { loading = false }
        do {
            let list = try await LLMSettings.client(provider, key: apiKey, model: "", baseURL: baseURL).listModels()
            try? ModelCache().save(list, for: provider, baseURL: baseURL)
            (models, fetched, error) = (list, .now, nil)
        } catch {
            self.error = ModelPickerView.message(for: error)
        }
    }

    /// What the user can do about a failed list call.
    static func message(for error: Error) -> String {
        if let e = error as? LLMError, let status = e.status {
            switch status {
            case 401, 403: return String(localized: "The provider rejected this key. Check it and try again.", table: "Account")
            case 404: return String(localized: "This server has no model list. Type a model ID instead.", table: "Account")
            default: break
            }
        }
        if error is URLError { return String(localized: "Can't reach the provider. Check your internet connection.", table: "Account") }
        return error.localizedDescription
    }
}

private struct ModelRow: View {
    let model: CloudModel
    let selected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name ?? model.id).font(.rowTitle).foregroundStyle(Color.ink)
                if model.name != nil { Text(model.id).font(.caption).foregroundStyle(Color.inkSecondary) }
                if !details.isEmpty || !tags.isEmpty {
                    HStack(spacing: 6) {
                        if !details.isEmpty { Text(details).font(.caption).foregroundStyle(Color.inkSecondary) }
                        ForEach(tags, id: \.self) { tag in
                            Text(tag).font(.caption2.weight(.semibold)).foregroundStyle(Color.brandDeep)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.brandMintSoft, in: .capsule)
                        }
                    }
                }
            }
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(Color.brandDeep).fontWeight(.semibold) }
        }
        .contentShape(.rect)
    }

    private var details: String {
        var parts: [String] = []
        if let c = model.contextLength {
            parts.append(String(localized: "\(c.formatted(.number.notation(.compactName))) context", table: "Account"))
        }
        if !model.isFree, let p = model.promptPrice, let c = model.completionPrice {
            let usd = FloatingPointFormatStyle<Double>.Currency(code: "USD").precision(.fractionLength(0...3))
            parts.append(String(localized: "\(p.formatted(usd)) / \(c.formatted(usd)) per 1M", table: "Account"))
        }
        return parts.joined(separator: " · ")
    }

    private var tags: [String] {
        var out: [String] = []
        if model.isFree { out.append(String(localized: "Free", table: "Account")) }
        if model.tools == true { out.append(String(localized: "Tools", table: "Account")) }
        if model.structuredOutputs == true { out.append("JSON") }
        return out
    }
}
