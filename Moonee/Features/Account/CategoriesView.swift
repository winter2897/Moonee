import SwiftData
import SwiftUI

struct CategoriesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Category.name) private var categories: [Category]
    @State private var addingKind: TxKind?
    @State private var newName = ""

    var body: some View {
        List {
            ForEach(TxKind.allCases, id: \.self) { kind in
                Section {
                    ForEach(categories.filter { $0.kind == kind }) { c in
                        HStack(spacing: 12) {
                            IconBadge(symbol: c.icon, color: c.color, size: 32)
                            Text(c.name)
                            Spacer()
                            if let jar = c.jar { Text(jar.name).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .onDelete { offsets in
                        let items = categories.filter { $0.kind == kind }
                        offsets.forEach { context.delete(items[$0]) }
                    }
                    Button("Thêm danh mục", systemImage: "plus") { newName = ""; addingKind = kind }
                } header: {
                    Text(kind.title)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .navigationTitle("Danh mục")
        .alert("Danh mục mới", isPresented: Binding(get: { addingKind != nil }, set: { if !$0 { addingKind = nil } })) {
            TextField("Tên", text: $newName)
            Button("Huỷ", role: .cancel) {}
            Button("Thêm") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if let kind = addingKind, !name.isEmpty {
                    context.insert(Category(name: name, icon: "tag.fill", colorHex: 0x64748B, kind: kind))
                }
            }
        }
    }
}
