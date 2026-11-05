import SwiftUI

/// Account → AI → Local models (spec §9.2): the curated catalog, a recommendation for this phone's RAM,
/// download with progress (Wi-Fi only by default, resumable), pick the one Moonee uses, delete to free space.
struct LocalModelsView: View {
    @State private var downloads = LocalModelDownloads.shared
    @AppStorage(LocalModelDownloads.wifiOnlyKey) private var wifiOnly = true
    @AppStorage(LocalModelDownloads.selectedKey) private var selected = ""
    @State private var confirmDelete: LocalModel?

    private let recommended = LocalModel.recommended()
    private let ram = ProcessInfo.processInfo.physicalMemory

    var body: some View {
        List {
            Section {
                Toggle(isOn: $wifiOnly) { Text("Download over Wi-Fi only", tableName: "LocalModels") }
            } header: {
                Text("This iPhone has \(Int64(ram).formatted(.byteCount(style: .memory))) of RAM.", tableName: "LocalModels")
                    .textCase(nil)
            } footer: {
                if !LocalLLM.isSupported {
                    Text("Local models need a real iPhone: the Simulator has no GPU for them.", tableName: "LocalModels")
                } else if recommended == nil {
                    Text("This iPhone has too little memory for a local model. Use Apple Intelligence or your own API key instead.", tableName: "LocalModels")
                } else {
                    Text("Models run fully on this iPhone: private, offline and free. They are downloaded from Hugging Face, never bundled with the app.", tableName: "LocalModels")
                }
            }

            ForEach(LocalModel.catalog) { model in
                Section { row(model) }
            }
        }
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .foregroundStyle(Color.mooneeInk)
        .navigationTitle(Text("Local models", tableName: "LocalModels"))
        .confirmationDialog(Text("Delete this model?", tableName: "LocalModels"), isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { m in
            Button(role: .destructive) { downloads.delete(m) } label: {
                Text("Delete \(m.name)", tableName: "LocalModels")
            }
        } message: { m in
            Text("Frees \(m.downloadBytes.formatted(.byteCount(style: .file))). You can download it again later.", tableName: "LocalModels")
        }
    }

    private func row(_ m: LocalModel) -> some View {
        let fits = m.fits(physicalMemory: ram)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(m.name).font(.rowTitle)
                if m == recommended {
                    Text("Recommended", tableName: "LocalModels")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundStyle(.white)
                        .background(LinearGradient.brand, in: .capsule)
                }
                Spacer()
                if selected == m.id, downloads.state(m) == .downloaded {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.mooneeGreen)
                }
            }
            Text("\(m.downloadBytes.formatted(.byteCount(style: .file))) download · needs \(m.ramBytes.formatted(.byteCount(style: .memory))) RAM · about \(m.tokensPerSecond) words/s",
                 tableName: "LocalModels")
                .font(.secondaryText)
            HStack(spacing: 12) {
                Label {
                    m.vietnamese == .good ? Text("Vietnamese: good", tableName: "LocalModels") : Text("Vietnamese: basic", tableName: "LocalModels")
                } icon: { Image(systemName: "character.bubble") }
                Label {
                    m.readsImages ? Text("Reads photos", tableName: "LocalModels") : Text("Text only", tableName: "LocalModels")
                } icon: { Image(systemName: m.readsImages ? "photo" : "text.alignleft") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Link(destination: m.licenceURL) { Text("Licence: \(m.licence)", tableName: "LocalModels") }.font(.caption)
            if fits {
                actions(m)
            } else {
                Text("Needs an iPhone with \(m.minDeviceRAMGB) GB of RAM or more.", tableName: "LocalModels")
                    .font(.caption).foregroundStyle(Color.warningText)
            }
        }
        .padding(.vertical, 4)
    }

    /// Small capsule actions inside the model's card (design system: filled = main action, outlined = secondary).
    @ViewBuilder private func actions(_ m: LocalModel) -> some View {
        switch downloads.state(m) {
        case .notDownloaded:
            pill("Download", "arrow.down", filled: true) { downloads.start(m) }
        case .downloading(let f), .waitingForWiFi(let f):
            ProgressView(value: f) {
                if case .waitingForWiFi = downloads.state(m) {
                    Text("Waiting for Wi-Fi…", tableName: "LocalModels").font(.caption)
                } else {
                    Text("Downloading \(f.formatted(.percent.precision(.fractionLength(0))))", tableName: "LocalModels").font(.caption)
                }
            }
            .tint(.mooneeGreen)
            pill("Pause", "pause.fill") { downloads.pause(m) }
        case .paused(let f):
            HStack(spacing: 8) {
                pill("Resume (\(f.formatted(.percent.precision(.fractionLength(0)))) done)", "arrow.clockwise", filled: true) { downloads.start(m) }
                pill("Delete", "trash") { confirmDelete = m }
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(Color.danger)
            HStack(spacing: 8) {
                pill("Try again", "arrow.clockwise", filled: true) { downloads.start(m) }
                pill("Delete", "trash") { confirmDelete = m }
            }
        case .downloaded:
            HStack(spacing: 8) {
                if selected != m.id { pill("Use this model", "checkmark", filled: true) { selected = m.id } }
                pill("Delete", "trash") { confirmDelete = m }
            }
        }
    }

    private func pill(_ title: LocalizedStringKey, _ symbol: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label { Text(title, tableName: "LocalModels") } icon: { Image(systemName: symbol) } }
            .labelStyle(.titleAndIcon) // a List row would otherwise show the icon only
            .buttonStyle(OutlinePillStyle(filled: filled))
    }
}

#Preview {
    NavigationStack { LocalModelsView() }
}
