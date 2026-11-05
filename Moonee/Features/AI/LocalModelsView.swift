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

    @ViewBuilder private func row(_ m: LocalModel) -> some View {
        let fits = m.fits(physicalMemory: ram)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(m.name).font(.headline)
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
                .font(.subheadline)
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
            if !fits {
                Text("Needs an iPhone with \(m.minDeviceRAMGB) GB of RAM or more.", tableName: "LocalModels")
                    .font(.caption).foregroundStyle(Color.warningText)
            }
        }
        .padding(.vertical, 4)

        actions(m, fits: fits)
    }

    @ViewBuilder private func actions(_ m: LocalModel, fits: Bool) -> some View {
        switch downloads.state(m) {
        case .notDownloaded:
            Button { downloads.start(m) } label: { Label { Text("Download", tableName: "LocalModels") } icon: { Image(systemName: "arrow.down.circle") } }
                .disabled(!fits)
        case .downloading(let f), .waitingForWiFi(let f):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: f) {
                    if case .waitingForWiFi = downloads.state(m) {
                        Text("Waiting for Wi-Fi…", tableName: "LocalModels").font(.caption)
                    } else {
                        Text("Downloading \(f.formatted(.percent.precision(.fractionLength(0))))", tableName: "LocalModels").font(.caption)
                    }
                }
                .tint(.mooneeGreen)
                Button { downloads.pause(m) } label: { Label { Text("Pause", tableName: "LocalModels") } icon: { Image(systemName: "pause.circle") } }
            }
        case .paused(let f):
            Button { downloads.start(m) } label: {
                Label { Text("Resume (\(f.formatted(.percent.precision(.fractionLength(0)))) done)", tableName: "LocalModels") } icon: { Image(systemName: "arrow.clockwise.circle") }
            }
            deleteButton(m)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(Color.danger)
            Button { downloads.start(m) } label: { Label { Text("Try again", tableName: "LocalModels") } icon: { Image(systemName: "arrow.clockwise.circle") } }
            deleteButton(m)
        case .downloaded:
            if selected != m.id {
                Button { selected = m.id } label: { Label { Text("Use this model", tableName: "LocalModels") } icon: { Image(systemName: "checkmark.circle") } }
            }
            deleteButton(m)
        }
    }

    private func deleteButton(_ m: LocalModel) -> some View {
        Button(role: .destructive) { confirmDelete = m } label: {
            Label { Text("Delete", tableName: "LocalModels") } icon: { Image(systemName: "trash") }
        }
    }
}

#Preview {
    NavigationStack { LocalModelsView() }
}
