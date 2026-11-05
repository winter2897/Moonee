import SwiftData
import SwiftUI

/// Transactions → CSV with fixed English headers (spec §10.5), so a file re-imports whatever the UI language.
/// Amounts are positive decimals in major units ("12.50"); `type` says which way the money moved.
/// Default categories/jars are written by key (`category.food`), user-named ones by their name.
enum CSVExport {
    static let header = ["date", "type", "amount", "currency", "category", "wallet", "to_wallet", "jar", "to_jar", "person", "note"]

    static func csv(_ txns: [Txn], timeZone: TimeZone = .current) -> String {
        let dateStyle = Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false).timeSeparator(.colon).dateTimeSeparator(.space)
        func name(_ c: Category?) -> String { c.map { $0.customName ?? $0.key ?? "" } ?? "" }
        func name(_ j: Jar?) -> String { j.map { $0.customName ?? $0.key ?? "" } ?? "" }
        let rows: [[String]] = txns.sorted { $0.date < $1.date }.map { t in
            let major: Decimal = t.money.major
            return [t.date.formatted(dateStyle), t.kind.rawValue, "\(major)", t.currencyCode, name(t.category),
                    t.wallet?.name ?? "", t.toWallet?.name ?? "", name(t.jar), name(t.toJar), t.debt?.person ?? "", t.note]
        }
        return ([header] + rows).map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180 quoting; text that a spreadsheet would run as a formula gets a leading apostrophe.
    static func field(_ s: String) -> String {
        var s = s
        if let first = s.first, "=+-@\t\r".contains(first), Double(s) == nil { s = "'" + s }
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Writes the file to tmp for the share sheet.
    static func file(_ txns: [Txn]) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "moonee-\(Date.now.formatted(.iso8601.year().month().day())).csv")
        try csv(txns).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

enum DataReset {
    /// Deletes every record (with iCloud sync on, the deletes sync too), clears the app's settings, then seeds
    /// the default jars/categories/wallet again so the app works like a fresh install.
    @MainActor static func deleteAll(_ context: ModelContext, defaults: UserDefaults = .standard,
                                     domain: String? = Bundle.main.bundleIdentifier) throws {
        for model in Schema.mooneeModels { try deleteAll(model, in: context) }
        try context.save()
        if let domain { defaults.removePersistentDomain(forName: domain) }
        Seed.ifNeeded(context)
        try context.save()
    }

    private static func deleteAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws {
        try context.delete(model: type)
    }

    /// Everything above plus the BYOK keys in Keychain.
    @MainActor static func eraseEverything(_ context: ModelContext) throws {
        try deleteAll(context)
        CloudProvider.allCases.forEach { LLMSettings.setAPIKey(nil, for: $0) }
    }
}

/// Account → Data (spec §6.3).
struct DataView: View {
    @Environment(\.modelContext) private var context
    @Query private var txns: [Txn]
    @State private var exportURL: URL?
    @State private var confirmStep = 0
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text("Off", tableName: "Account")
                } label: {
                    Label { Text("iCloud sync", tableName: "Account") } icon: { Image(systemName: "icloud") }
                }
            } footer: {
                // ponytail: static until S11 adds the iCloud capability; then read the real sync state.
                Text("Your data is stored on this iPhone only. iCloud backup and sync come in a later update.", tableName: "Account")
            }

            Section {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label { Text("Export CSV", tableName: "Account") } icon: { Image(systemName: "square.and.arrow.up") }
                    }
                }
            } footer: {
                Text("\(txns.count) transactions. Column names stay in English so the file imports back in any language.", tableName: "Account")
            }

            Section {
                Button(role: .destructive) { confirmStep = 1 } label: {
                    Label { Text("Delete all data", tableName: "Account") } icon: { Image(systemName: "trash") }
                }
            } footer: {
                if let error { Text(error).foregroundStyle(Color.danger) }
                else { Text("Removes every transaction, wallet, jar, goal and setting from this iPhone. This cannot be undone.", tableName: "Account") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .navigationTitle(Text("Data", tableName: "Account"))
        .task(id: txns.count) { exportURL = try? CSVExport.file(txns) }
        .confirmationDialog(Text("Delete all data?", tableName: "Account"), isPresented: Binding(get: { confirmStep == 1 }, set: { if !$0 && confirmStep == 1 { confirmStep = 0 } }), titleVisibility: .visible) {
            Button(String(localized: "Continue", table: "Account"), role: .destructive) { confirmStep = 2 }
        } message: {
            Text("Export a CSV first if you may want your data later.", tableName: "Account")
        }
        .alert(Text("Delete everything for good?", tableName: "Account"), isPresented: Binding(get: { confirmStep == 2 }, set: { if !$0 { confirmStep = 0 } })) {
            Button(String(localized: "Delete everything", table: "Account"), role: .destructive) {
                do { try DataReset.eraseEverything(context) } catch { self.error = error.localizedDescription }
            }
            Button(String(localized: "Cancel", table: "Account"), role: .cancel) {}
        } message: {
            Text("Moonee starts again like a new install.", tableName: "Account")
        }
    }
}
