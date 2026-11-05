import SwiftData
import SwiftUI

/// Editable copy of a jar; nothing touches SwiftData until the percents sum to 100 and the user saves.
struct JarDraft: Identifiable {
    let id = UUID()
    var jar: Jar?
    /// Default jars keep their key; the name is only stored when the user changes it.
    var key: String?
    var name: String
    var icon: String
    var colorHex: Int
    var percent: Int

    init(_ jar: Jar, existing: Jar? = nil) {
        self.jar = existing
        key = jar.key
        name = jar.name
        icon = jar.icon
        colorHex = jar.colorHex
        percent = jar.percent
    }

    init(colorHex: Int = JarPalette.hex[6]) {
        name = String(localized: "New jar")
        icon = "star.fill"
        self.colorHex = colorHex
        percent = 0
    }

    /// nil while the name is still the default jar's translated name.
    var customName: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return key.map { String(localized: String.LocalizationValue($0)) } == trimmed ? nil : trimmed
    }
}

struct JarSettingsView: View {
    /// Opens the editor for a new jar right away (Budget's "Add jar").
    var startAdding = false
    /// Opens the editor for this jar right away (jar detail's "Edit").
    var editJar: PersistentIdentifier?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Jar.order) private var jars: [Jar]
    @State private var drafts: [JarDraft] = []
    @State private var editing: Int?
    @State private var loaded = false

    private var remainder: Int { BudgetActions.percentRemainder(drafts.map(\.percent)) }
    private var canSave: Bool {
        BudgetActions.percentsValid(drafts.map(\.percent)) && drafts.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        List {
            Section {
                ForEach($drafts) { $d in
                    HStack(spacing: 12) {
                        Button { editing = drafts.firstIndex { $0.id == d.id } } label: {
                            HStack(spacing: 12) {
                                IconBadge(symbol: d.icon, color: Color(hex: d.colorHex), size: 34)
                                Text(d.name).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Stepper("\(d.percent)%", value: $d.percent, in: 0...100)
                            .fixedSize()
                            .monospacedDigit()
                    }
                }
                .onDelete { drafts.remove(atOffsets: $0) }
                .onMove { drafts.move(fromOffsets: $0, toOffset: $1) }

                Button("Add jar", systemImage: "plus") { addJar() }
            } header: {
                remainderHeader
            }

            Section {
                Button("Restore defaults", systemImage: "arrow.counterclockwise") { resetDefaults() }
            } footer: {
                Text(Seed.defaultJars.map { "\($0.percent)% \($0.name)" }.joined(separator: " · "))
            }
        }
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .foregroundStyle(Color.mooneeInk)
        .navigationTitle("Customize jars")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }.fontWeight(.semibold).disabled(!canSave)
            }
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let i = editing, drafts.indices.contains(i) { JarEditor(draft: $drafts[i]) }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            drafts = jars.map { JarDraft($0, existing: $0) }
            if startAdding { addJar() }
            if let editJar { editing = drafts.firstIndex { $0.jar?.persistentModelID == editJar } }
        }
    }

    private var remainderHeader: some View {
        HStack {
            Text("Total \(100 - remainder)%")
            Spacer()
            if remainder == 0 {
                Label("Adds up to 100%", systemImage: "checkmark.circle.fill").foregroundStyle(Color.mooneeDark)
            } else {
                Label(remainder > 0 ? "\(remainder)% left" as LocalizedStringKey : "\(-remainder)% over", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.subheadline.weight(.semibold))
        .textCase(nil)
    }

    /// New jars take the first palette colour no jar uses yet.
    private func addJar() {
        let used = Set(drafts.map(\.colorHex))
        drafts.append(JarDraft(colorHex: JarPalette.hex.first { !used.contains($0) } ?? JarPalette.hex[drafts.count % JarPalette.hex.count]))
        editing = drafts.count - 1
    }

    /// Reuses jars with a default key so their categories stay linked; other jars are removed on save.
    private func resetDefaults() {
        let current = drafts
        drafts = Seed.defaultJars.map { def in JarDraft(def, existing: current.first { $0.key == def.key }?.jar) }
    }

    private func save() {
        let kept = Set(drafts.compactMap { $0.jar.map(ObjectIdentifier.init) })
        for jar in jars where !kept.contains(ObjectIdentifier(jar)) { context.delete(jar) }
        for (i, d) in drafts.enumerated() {
            let jar = d.jar ?? {
                let j = Jar(key: d.key, icon: d.icon, colorHex: d.colorHex, percent: d.percent, order: i)
                context.insert(j)
                return j
            }()
            jar.customName = d.customName
            jar.icon = d.icon
            jar.colorHex = d.colorHex
            jar.percent = d.percent
            jar.order = i
        }
        dismiss()
    }
}

private struct JarEditor: View {
    @Binding var draft: JarDraft
    @Environment(\.dismiss) private var dismiss

    static let icons = ["house.fill", "chart.line.uptrend.xyaxis", "banknote.fill", "book.fill", "sparkles", "heart.fill",
                        "star.fill", "gift.fill", "airplane", "car.fill", "graduationcap.fill", "cross.case.fill",
                        "gamecontroller.fill", "cart.fill", "fork.knife", "leaf.fill", "pawprint.fill", "shield.fill"]
    /// S2's colour-blind-safe jar palette.
    static let colors = JarPalette.hex

    var body: some View {
        NavigationStack {
            Form {
                Section("Jar name") { TextField("Name", text: $draft.name) }
                Section("Share") {
                    Stepper("\(draft.percent)% of income", value: $draft.percent, in: 0...100)
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Self.icons, id: \.self) { icon in
                            IconBadge(symbol: icon, color: Color(hex: draft.colorHex), size: 40)
                                .overlay { if icon == draft.icon { Circle().stroke(Color(hex: draft.colorHex), lineWidth: 2) } }
                                .onTapGesture { draft.icon = icon }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Self.colors, id: \.self) { hex in
                            Circle().fill(Color(hex: hex)).frame(width: 34, height: 34)
                                .overlay { if hex == draft.colorHex { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } }
                                .onTapGesture { draft.colorHex = hex }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(draft.name.isEmpty ? String(localized: "Jar") : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.fontWeight(.semibold) }
        }
        .presentationDetents([.large])
    }
}
