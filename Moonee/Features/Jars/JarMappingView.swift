import SwiftData
import SwiftUI

/// Pick the jar each expense category draws from. Changes apply immediately.
struct JarMappingView: View {
    @Query(sort: \Category.order) private var allCategories: [Category]
    @Query(sort: \Jar.order) private var jars: [Jar]

    private var categories: [Category] { allCategories.filter { $0.kind == .expense } }

    var body: some View {
        let unassigned = categories.filter { $0.jar == nil }
        List {
            if !unassigned.isEmpty {
                Section {
                    ForEach(unassigned) { row($0) }
                } header: {
                    Label("No jar (\(unassigned.count))", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).textCase(nil)
                } footer: {
                    Text("Spending in these categories is not counted in any jar. Pick one, or keep it out in the category's Advanced settings.", tableName: "Account")
                }
            }
            Section("Assigned") {
                ForEach(categories.filter { $0.jar != nil }) { row($0) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .navigationTitle("Assign categories")
    }

    private func row(_ c: Category) -> some View {
        Picker(selection: Binding(get: { c.jar }, set: { c.jar = $0 })) {
            if c.jar == nil { Text("No jar").tag(nil as Jar?) } // set only in the category's Advanced settings (P0-2)
            ForEach(jars) { Label($0.name, systemImage: $0.icon).tag($0 as Jar?) }
        } label: {
            Label { Text(c.name) } icon: { Image(systemName: c.icon).foregroundStyle(c.color) }
        }
        .pickerStyle(.menu)
        .tint(c.jar == nil ? .orange : .mooneeDark)
    }
}
