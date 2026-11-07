import SwiftData
import SwiftUI

struct CategoriesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Category.order) private var categories: [Category]
    @State private var editing: CategoryDraft?

    var body: some View {
        List {
            ForEach([TxKind.expense, .income], id: \.self) { kind in
                Section {
                    ForEach(categories.filter { $0.kind == kind }) { c in
                        Button { editing = .init(category: c, kind: kind) } label: {
                            HStack(spacing: 12) {
                                IconBadge(symbol: c.icon, color: c.color, size: 32)
                                Text(c.name).foregroundStyle(Color.ink)
                                Spacer()
                                if let jar = c.jar {
                                    Text(jar.name).font(.caption).foregroundStyle(Color.inkSecondary)
                                } else if kind == .expense {
                                    Text("Not in any jar", tableName: "Account").font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        let items = categories.filter { $0.kind == kind }
                        offsets.forEach { context.delete(items[$0]) }
                    }
                    Button("Add category", systemImage: "plus") { editing = .init(category: nil, kind: kind) }
                } header: {
                    Text(kind.title)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .navigationTitle("Categories")
        .sheet(item: $editing) { d in CategoryForm(category: d.category, kind: d.kind, order: categories.count) }
    }
}

struct CategoryDraft: Identifiable {
    let id = UUID()
    var category: Category?
    var kind: TxKind
}

/// New or edit a category. An expense category must pick its jar (P0-2: no orphan spending); "Not in any jar" is an
/// Advanced choice that says where that spending goes.
struct CategoryForm: View {
    let category: Category?
    let kind: TxKind
    var order = 0
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Jar.order) private var jars: [Jar]
    @State private var name = ""
    @State private var jar: Jar?
    @State private var noJar = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $name) { Text("Name", tableName: "Account") }
                    if kind == .expense, !noJar {
                        Picker(selection: $jar) {
                            ForEach(jars) { Label($0.name, systemImage: $0.icon).tag(Optional($0)) }
                        } label: { Text("Jar", tableName: "Account") }
                    }
                } footer: {
                    if kind == .expense, !noJar { Text("Spending in this category comes out of this jar.", tableName: "Account") }
                }
                if kind == .expense {
                    Section {
                        Toggle(isOn: $noJar) { Text("Not in any jar", tableName: "Account") }
                    } header: {
                        Text("Advanced", tableName: "Account")
                    } footer: {
                        Text("Spending here comes out of Unallocated, not a jar, and Budget's Spent leaves it out.", tableName: "Account")
                    }
                }
            }
            .navigationTitle(category == nil ? String(localized: "New category", table: "Account") : String(localized: "Edit category", table: "Account"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text("Cancel", tableName: "Account") } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) { Text("Save", tableName: "Account") }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (kind == .expense && !noJar && jar == nil))
                }
            }
            .onAppear {
                name = category?.name ?? ""
                jar = category?.jar ?? (category == nil ? jars.first { $0.key == "jar.essentials" } ?? jars.first : nil)
                noJar = kind == .expense && category != nil && category?.jar == nil
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let c = category ?? Category(customName: trimmed, icon: "tag.fill", colorHex: 0x64748B, kind: kind, order: order)
        if category == nil { context.insert(c) }
        if trimmed != c.name { c.customName = trimmed }
        if kind == .expense { c.jar = noJar ? nil : jar } // future spends only: past ones keep their pinned jar
        dismiss()
    }
}
