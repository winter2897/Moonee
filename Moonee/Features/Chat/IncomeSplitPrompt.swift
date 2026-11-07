import SwiftData
import SwiftUI

/// Under a chat card with money in (spec §4.1, P0-1). Split: what each jar got, with Undo (back to Unallocated) and Edit.
/// Not split yet (Suggest, or after Undo) while the money still waits in Unallocated: split it as Moonee suggests, by
/// percent, or later (the Budget card offers the same).
struct IncomeSplitPrompt: View {
    let txn: Txn
    var onEdit: () -> Void
    @Environment(\.modelContext) private var context
    @Query private var txns: [Txn]
    @Query private var wallets: [Wallet]
    @Query(sort: \Jar.order) private var jars: [Jar]
    @AppStorage(Prefs.advisorLevel) private var level = AdvisorLevel.suggest.rawValue
    // ponytail: "Later" lasts while the chat is open; the money still waits in Unallocated and the Budget card offers it.
    @State private var later = false

    var body: some View {
        let splits = (txn.splits ?? []).filter { $0.amount > 0 }.sorted { ($0.jar?.order ?? 0) < ($1.jar?.order ?? 0) }
        if !splits.isEmpty {
            let parts = splits.map { "\($0.jar?.name ?? "") \(short($0.amount))" }.joined(separator: " · ")
            panel(symbol: "square.split.2x2.fill",
                  text: level == AdvisorLevel.automatic.rawValue ? String(localized: "Moonee split it: \(parts)", table: "Chat")
                                                                 : String(localized: "Split into jars: \(parts)", table: "Chat")) {
                Button { withAnimation { unsplit() } } label: { Text("Undo", tableName: "Chat") }
            } more: {
                Button(action: onEdit) { Text("Edit", tableName: "Chat") }
            }
        } else if !later, Ledger(txns: txns, wallets: wallets, jars: jars).unallocated >= txn.amount {
            panel(symbol: "tray.full.fill",
                  text: String(localized: "**\(short(txn.amount))** is waiting in Unallocated. Split it now?", table: "Chat")) {
                Button { split(.automatic) } label: { Text("Split as Moonee suggests", tableName: "Chat") }
                    .buttonStyle(OutlinePillStyle(filled: true))
            } more: {
                Button { split(.manual) } label: { Text("By %", tableName: "Chat") }
                Button { withAnimation { later = true } } label: { Text("Later", tableName: "Chat") }
            }
        }
    }

    /// Buttons on one row, or the first alone above the others when they don't fit.
    private func panel(symbol: String, text: String, @ViewBuilder first: () -> some View, @ViewBuilder more: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label { Text(LocalizedStringKey(text)) } icon: { Image(systemName: symbol).foregroundStyle(Color.brandPrimary) }
                .font(.secondaryText).foregroundStyle(Color.ink)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { first(); more() }
                VStack(alignment: .leading, spacing: 6) { first(); HStack(spacing: 6) { more() } }
            }
            .buttonStyle(OutlinePillStyle())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.brandMintSoft.opacity(0.7), in: .rect(cornerRadius: 14))
    }

    private func short(_ minor: Int) -> String { AmountFormat.string(minor, txn.currencyCode, short: true) }

    /// "Split as Moonee suggests" = the Automatic rule, "By %" = Do it myself, on this one income.
    private func split(_ level: AdvisorLevel) {
        withAnimation { _ = BudgetActions.receive(income: txn, level: level, in: context) }
        try? context.save()
    }

    private func unsplit() {
        (txn.splits ?? []).forEach(context.delete)
        txn.splits = []
        later = true // just undone: don't offer it again right away
        try? context.save()
    }
}
