import SwiftUI

struct AISettingsView: View {
    @AppStorage(LLMSettings.providerKey) private var provider = LLMProvider.remote
    @AppStorage(LLMSettings.modelKey) private var model = LLMSettings.defaultModel
    @AppStorage(LLMSettings.baseURLKey) private var baseURL = LLMSettings.defaultBaseURL
    @State private var apiKey = LLMSettings.apiKey ?? ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("Nhà cung cấp AI") {
                Picker("Nhà cung cấp", selection: $provider) {
                    ForEach(LLMProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                if provider == .remote {
                    SecureField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .onChange(of: apiKey) { LLMSettings.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
                    LabeledContent("Model") {
                        TextField(LLMSettings.defaultModel, text: $model).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Base URL") {
                        TextField(LLMSettings.defaultBaseURL, text: $baseURL).multilineTextAlignment(.trailing).keyboardType(.URL)
                    }
                } else {
                    LabeledContent("Model", value: "Apple Intelligence")
                    Text(LLMSettings.appleStatus).font(.footnote).foregroundStyle(.secondary)
                }

                Button {
                    test()
                } label: {
                    HStack {
                        Text("Kiểm tra kết nối")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing)
                if let testResult { Text(testResult).font(.footnote) }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .navigationTitle("Cài đặt AI")
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            do {
                let reply = try await LLMSettings.current().complete(system: "Trả lời đúng một từ.", user: "Nói 'OK' bằng tiếng Việt.")
                testResult = "✅ Kết nối được: \(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))"
            } catch {
                testResult = "❌ \(error.localizedDescription)"
            }
            testing = false
        }
    }
}
