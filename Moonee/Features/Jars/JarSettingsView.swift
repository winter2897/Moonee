import SwiftData
import SwiftUI

/// Editable copy of a jar; nothing touches SwiftData until the percents sum to 100 and the user saves.
struct JarDraft: Identifiable {
    let id = UUID()
    var jar: Jar?
    var name: String
    var icon: String
    var colorHex: Int
    var percent: Int

    init(_ jar: Jar, existing: Jar? = nil) {
        self.jar = existing
        name = jar.name
        icon = jar.icon
        colorHex = jar.colorHex
        percent = jar.percent
    }

    init() {
        name = "Lọ mới"
        icon = "star.fill"
        colorHex = 0x64748B
        percent = 0
    }
}

struct JarSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Jar.order) private var jars: [Jar]
    @State private var drafts: [JarDraft] = []
    @State private var editing: Int?
    @State private var loaded = false

    private var remainder: Int { 100 - drafts.reduce(0) { $0 + $1.percent } }
    private var canSave: Bool {
        remainder == 0 && !drafts.isEmpty && drafts.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
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

                Button("Thêm lọ", systemImage: "plus") {
                    drafts.append(JarDraft())
                    editing = drafts.count - 1
                }
            } header: {
                remainderHeader
            }

            Section {
                Button("Khôi phục mặc định", systemImage: "arrow.counterclockwise") { resetDefaults() }
            } footer: {
                Text("55% Thiết yếu · 10% Đầu tư · 10% Tiết kiệm · 10% Phát triển bản thân · 10% Hưởng thụ · 5% Từ thiện")
            }
        }
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .foregroundStyle(Color.mooneeInk)
        .navigationTitle("Tuỳ chỉnh lọ")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Lưu") { save() }.fontWeight(.semibold).disabled(!canSave)
            }
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let i = editing, drafts.indices.contains(i) { JarEditor(draft: $drafts[i]) }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            drafts = jars.map { JarDraft($0, existing: $0) }
        }
    }

    private var remainderHeader: some View {
        HStack {
            Text("Tổng \(100 - remainder)%")
            Spacer()
            if remainder == 0 {
                Label("Đủ 100%", systemImage: "checkmark.circle.fill").foregroundStyle(Color.mooneeDark)
            } else {
                Label(remainder > 0 ? "Còn \(remainder)%" : "Thừa \(-remainder)%", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.subheadline.weight(.semibold))
        .textCase(nil)
    }

    /// Reuses jars with a default name so their categories stay linked; other jars are removed on save.
    private func resetDefaults() {
        let current = drafts
        drafts = Seed.defaultJars.map { def in JarDraft(def, existing: current.first { $0.name == def.name }?.jar) }
    }

    private func save() {
        let kept = Set(drafts.compactMap { $0.jar.map(ObjectIdentifier.init) })
        for jar in jars where !kept.contains(ObjectIdentifier(jar)) { context.delete(jar) }
        for (i, d) in drafts.enumerated() {
            let jar = d.jar ?? {
                let j = Jar(name: d.name, icon: d.icon, colorHex: d.colorHex, percent: d.percent, order: i)
                context.insert(j)
                return j
            }()
            jar.name = d.name.trimmingCharacters(in: .whitespaces)
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
    static let colors = [0x22C55E, 0x3B82F6, 0x14B8A6, 0x8B5CF6, 0xF59E0B, 0xEF4444, 0xEC4899, 0x6366F1, 0xEAB308, 0x64748B]

    var body: some View {
        NavigationStack {
            Form {
                Section("Tên lọ") { TextField("Tên", text: $draft.name) }
                Section("Tỉ lệ") {
                    Stepper("\(draft.percent)% thu nhập", value: $draft.percent, in: 0...100)
                }
                Section("Biểu tượng") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Self.icons, id: \.self) { icon in
                            IconBadge(symbol: icon, color: Color(hex: draft.colorHex), size: 40)
                                .overlay { if icon == draft.icon { Circle().stroke(Color(hex: draft.colorHex), lineWidth: 2) } }
                                .onTapGesture { draft.icon = icon }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Màu") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(Self.colors, id: \.self) { hex in
                            Circle().fill(Color(hex: hex)).frame(width: 34, height: 34)
                                .overlay { if hex == draft.colorHex { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } }
                                .onTapGesture { draft.colorHex = hex }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(draft.name.isEmpty ? "Lọ" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Xong") { dismiss() }.fontWeight(.semibold) }
        }
        .presentationDetents([.large])
    }
}
