import SwiftUI

/// Account → AI → Manage models (spec §9.2): what is downloaded (pick the one Moonee uses, delete, test speed), then the
/// featured model families. Only models this phone can run are listed; a family opens its variants.
struct LocalModelsView: View {
    @State private var downloads = LocalModelDownloads.shared
    @AppStorage(LocalModelDownloads.wifiOnlyKey) private var wifiOnly = true
    @State private var confirmDelete: LocalModel?

    private let device = DeviceMemory.current

    var body: some View {
        let recommended = LocalModel.recommended(on: device)
        let mine = LocalModel.catalog.filter { downloads.state($0) != .notDownloaded }
        let families = LocalModelFamily.all.filter { $0.models.contains { $0.runs(on: device) } }
        List {
            if !mine.isEmpty {
                Section {
                    ForEach(mine) { LocalModelRow(model: $0, title: $0.name, device: device, recommended: recommended, confirmDelete: $confirmDelete) }
                } header: {
                    Text("Downloaded", tableName: "LocalModels")
                }
            }

            if families.isEmpty {
                Section {
                    Text("This iPhone has too little memory for a local model. Use Apple Intelligence or your own API key instead.", tableName: "LocalModels")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(families) { f in
                        NavigationLink {
                            LocalFamilyView(family: f, device: device)
                        } label: {
                            FamilyCard(family: f, device: device, recommended: recommended)
                        }
                    }
                } header: {
                    Text("Featured", tableName: "LocalModels")
                }
            }

            Section {
                Toggle(isOn: $wifiOnly) { Text("Download over Wi-Fi only", tableName: "LocalModels") }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Models run fully on this iPhone: private, offline and free. They are downloaded from Hugging Face, never bundled with the app.", tableName: "LocalModels")
                    Text("This iPhone has \(device.physical.formatted(.byteCount(style: .memory))) of RAM; Moonee can use about \(device.usable.formatted(.byteCount(style: .memory))) for a model. Models that need more are hidden.", tableName: "LocalModels")
                    if !LocalLLM.isSupported {
                        Text("Local models need a real iPhone: the Simulator has no GPU for them.", tableName: "LocalModels")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .navigationTitle(Text("Manage models", tableName: "LocalModels"))
        .deleteModelDialog($confirmDelete)
    }
}

/// One family's variants (the ones this phone runs), with download and use actions.
struct LocalFamilyView: View {
    let family: LocalModelFamily
    let device: DeviceMemory
    @State private var confirmDelete: LocalModel?

    var body: some View {
        let recommended = LocalModel.recommended(on: device)
        let models = family.models.filter { $0.runs(on: device) }
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        IconBadge(symbol: family.symbol, color: .mooneeGreen, size: 44)
                        VStack(alignment: .leading) {
                            Text(family.name).font(.title3.weight(.semibold))
                            Text(family.maker).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Text(family.summary).font(.subheadline)
                }
                .padding(.vertical, 4)
            }
            Section {
                ForEach(models) { LocalModelRow(model: $0, title: $0.variant, device: device, recommended: recommended, confirmDelete: $confirmDelete) }
            } header: {
                Text("\(models.count) models for this iPhone", tableName: "LocalModels")
            } footer: {
                Link(destination: family.licenceURL) { Text("Licence: \(family.licence)", tableName: "LocalModels") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .navigationTitle(family.name)
        .navigationBarTitleDisplayMode(.inline)
        .deleteModelDialog($confirmDelete)
    }
}

private struct FamilyCard: View {
    let family: LocalModelFamily
    let device: DeviceMemory
    let recommended: LocalModel?

    var body: some View {
        let count = family.models.filter { $0.runs(on: device) }.count
        HStack(alignment: .top, spacing: 12) {
            IconBadge(symbol: family.symbol, color: .mooneeGreen, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(family.name).font(.headline)
                    Text(family.maker).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(family.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                HStack(spacing: 6) {
                    Text("\(count) models", tableName: "LocalModels").font(.caption).foregroundStyle(.secondary)
                    if family.isNew { ModelTag.new.view }
                    if family.models.contains(where: \.thinking) { ModelTag.thinking.view }
                    if recommended?.family == family { ModelTag.recommended.view }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// A model with its state: download → progress (pause) → use. Swipe or long-press to delete or test speed.
private struct LocalModelRow: View {
    let model: LocalModel
    let title: String
    let device: DeviceMemory
    let recommended: LocalModel?
    @Binding var confirmDelete: LocalModel?

    @State private var downloads = LocalModelDownloads.shared
    @AppStorage(LocalModelDownloads.selectedKey) private var selected = ""

    var body: some View {
        let state = downloads.state(model)
        let inUse = selected == model.id && state == .downloaded
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                if inUse {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.mooneeGreen)
                        .accessibilityLabel(Text("In use", tableName: "LocalModels"))
                }
                Spacer(minLength: 8)
                action(state, inUse: inUse)
            }
            tags
            Text(model.note).font(.subheadline).foregroundStyle(.secondary)
            Text("\(model.downloadBytes.formatted(.byteCount(style: .file))) · needs \(model.ramBytes.formatted(.byteCount(style: .memory))) of memory",
                 tableName: "LocalModels")
                .font(.footnote).foregroundStyle(.secondary)
            status(state)
        }
        .padding(.vertical, 2)
        .swipeActions {
            if state != .notDownloaded {
                Button(role: .destructive) { confirmDelete = model } label: {
                    Label { Text("Delete", tableName: "LocalModels") } icon: { Image(systemName: "trash") }
                }
            }
        }
        .contextMenu {
            if state == .downloaded {
                if !inUse {
                    Button { selected = model.id } label: {
                        Label { Text("Use this model", tableName: "LocalModels") } icon: { Image(systemName: "checkmark.circle") }
                    }
                }
                if LocalLLM.isSupported {
                    Button { downloads.testSpeed(model) } label: {
                        Label { Text("Test speed", tableName: "LocalModels") } icon: { Image(systemName: "speedometer") }
                    }
                }
            }
            if state != .notDownloaded {
                Button(role: .destructive) { confirmDelete = model } label: {
                    Label { Text("Delete", tableName: "LocalModels") } icon: { Image(systemName: "trash") }
                }
            }
        }
    }

    @ViewBuilder private var tags: some View {
        let heavy = model.isHeavy(on: device)
        if model == recommended || model.thinking || heavy {
            HStack(spacing: 6) {
                if model == recommended { ModelTag.recommended.view }
                if model.thinking { ModelTag.thinking.view }
                if heavy { ModelTag.highCPU.view }
            }
        }
    }

    @ViewBuilder private func status(_ state: LocalModelDownloads.State) -> some View {
        switch state {
        case .downloading(let f):
            ProgressView(value: f) {
                Text("Downloading \(f.formatted(.percent.precision(.fractionLength(0))))", tableName: "LocalModels").font(.caption)
            }
            .tint(.mooneeGreen)
        case .waitingForWiFi(let f):
            ProgressView(value: f) { Text("Waiting for Wi-Fi…", tableName: "LocalModels").font(.caption) }.tint(.mooneeGreen)
        case .paused(let f):
            Text("Paused at \(f.formatted(.percent.precision(.fractionLength(0))))", tableName: "LocalModels")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(Color.danger)
        case .downloaded:
            switch downloads.speeds[model.id] {
            case .running:
                Label { Text("Testing speed…", tableName: "LocalModels") } icon: { ProgressView().controlSize(.mini) }
                    .font(.caption).foregroundStyle(.secondary)
            case .done(let m):
                Text("First word in \(m.firstTokenSeconds.formatted(.number.precision(.fractionLength(1)))) s · \(Int(m.tokensPerSecond)) tokens/s",
                     tableName: "LocalModels")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(Color.danger)
            case nil:
                EmptyView()
            }
        case .notDownloaded:
            EmptyView()
        }
    }

    @ViewBuilder private func action(_ state: LocalModelDownloads.State, inUse: Bool) -> some View {
        switch state {
        case .notDownloaded:
            pill("Download") { downloads.start(model) }
        case .downloading, .waitingForWiFi:
            Button { downloads.pause(model) } label: {
                Image(systemName: "pause.circle.fill").font(.title2).foregroundStyle(Color.mooneeGreen)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Pause", tableName: "LocalModels"))
        case .paused:
            pill("Resume") { downloads.start(model) }
        case .failed:
            pill("Try again") { downloads.start(model) }
        case .downloaded:
            if inUse {
                Text("In use", tableName: "LocalModels").font(.subheadline).foregroundStyle(.secondary)
            } else {
                pill("Use") { selected = model.id }
            }
        }
    }

    /// App Store style: a small bordered capsule button.
    private func pill(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title, tableName: "LocalModels").font(.subheadline.weight(.semibold)) }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(.mooneeGreen)
    }
}

private enum ModelTag {
    case new, thinking, recommended, highCPU

    var view: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            switch self {
            case .new: Text("New", tableName: "LocalModels")
            case .thinking: Text("Thinking", tableName: "LocalModels")
            case .recommended: Text("Recommended", tableName: "LocalModels")
            case .highCPU: Text("High CPU usage", tableName: "LocalModels")
            }
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.12), in: .capsule)
    }

    private var symbol: String {
        switch self {
        case .new: "sparkles"
        case .thinking: "brain"
        case .recommended: "star.fill"
        case .highCPU: "flame"
        }
    }

    private var color: Color {
        switch self {
        case .new: .blue
        case .thinking: .indigo
        case .recommended: .mooneeGreen
        case .highCPU: .warningText
        }
    }
}

private extension View {
    func deleteModelDialog(_ model: Binding<LocalModel?>) -> some View {
        confirmationDialog(Text("Delete this model?", tableName: "LocalModels"), isPresented: Binding(
            get: { model.wrappedValue != nil }, set: { if !$0 { model.wrappedValue = nil } }), presenting: model.wrappedValue) { m in
            Button(role: .destructive) { LocalModelDownloads.shared.delete(m) } label: {
                Text("Delete \(m.name)", tableName: "LocalModels")
            }
        } message: { m in
            Text("Frees \(m.downloadBytes.formatted(.byteCount(style: .file))). You can download it again later.", tableName: "LocalModels")
        }
    }
}

#Preview {
    NavigationStack { LocalModelsView() }
}
