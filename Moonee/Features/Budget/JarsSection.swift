import SwiftData
import SwiftUI

/// Prefill for the "Move between jars" sheet.
struct JarTransferDraft: Identifiable {
    let id = UUID()
    var from: Jar?
    var to: Jar?
    var amount = 0
}

/// Jars section of the Budget list (spec §4.1): month, total, a fix for a negative jar, one row per jar.
struct JarsSection: View {
    @Binding var month: DateInterval
    @Binding var sheet: BudgetSheet?
    @Binding var path: NavigationPath
    @Query(sort: \Jar.order) private var jars: [Jar]
    @Query private var txns: [Txn]

    private let currency = Money.defaultCurrency

    var body: some View {
        let ledger = Ledger(txns: txns, wallets: [], jars: jars)
        let months = jars.map { ($0, ledger.jarMonth($0.persistentModelID, in: month)) }
        let budget = months.reduce(0) { $0 + $1.1.budget }, spent = months.reduce(0) { $0 + $1.1.spent }
        Section {
            monthPicker
            LabeledContent(loc("Total budget")) { AmountText(budget, currency: currency).foregroundStyle(Color.ink) }
            SpentProgress(spent: spent, budget: budget, currency: currency)
            LabeledContent(loc("Left")) { AmountText(budget - spent, currency: currency).foregroundStyle(Color.ink) }
        } header: {
            Text(loc("This month"))
        }

        Section {
            if let fix = suggestedFix(months) {
                Button { sheet = .transfer(fix) } label: {
                    Label {
                        Text(String(localized: "\(fix.to?.name ?? "") is below zero", table: "Budget")).foregroundStyle(Color.ink)
                        if let from = fix.from {
                            Text(String(localized: "Tap to move money from \(from.name).", table: "Budget")).font(.subheadline).foregroundStyle(Color.inkSecondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.danger)
                    }
                }
            }
            ForEach(months, id: \.0.persistentModelID) { jar, m in
                NavigationLink(value: BudgetRoute.jar(jar.persistentModelID, month: month.start)) { BudgetJarRow(jar: jar, month: m) }
                    .swipeActions(edge: .leading) {
                        Button(loc("Move money"), systemImage: "arrow.left.arrow.right") { sheet = .transfer(draft(for: jar, m)) }
                            .tint(Color.brandPrimary)
                    }
                    .contextMenu {
                        Button(loc("Move money"), systemImage: "arrow.left.arrow.right") { sheet = .transfer(draft(for: jar, m)) }
                        Button(loc("Edit jar"), systemImage: "pencil") { path.append(BudgetRoute.jarSettings(add: false, edit: jar.persistentModelID)) }
                    }
            }
        } header: {
            Text(loc("Jars"))
        } footer: {
            Text(String(localized: "Income split: \(jars.map { "\($0.percent)%" }.joined(separator: " · "))", table: "Budget"))
        }
    }

    private var monthPicker: some View {
        let cal = Calendar.current
        let recent = (0..<12).compactMap { cal.date(byAdding: .month, value: -$0, to: .now).flatMap { cal.dateInterval(of: .month, for: $0) } }
        return Picker(loc("Month"), selection: $month) {
            ForEach(recent, id: \.start) { Text($0.start.budgetMonthTitle).tag($0) }
        }
        .pickerStyle(.menu)
    }

    /// Swipe "Move money": a jar with money gives, a jar without receives.
    private func draft(for jar: Jar, _ m: Ledger<PersistentIdentifier>.JarMonth) -> JarTransferDraft {
        m.endBalance > 0 ? JarTransferDraft(from: jar) : JarTransferDraft(to: jar)
    }

    /// Spec §4.1: a negative jar gets a warning and a suggested transfer from the jar with the most money.
    private func suggestedFix(_ months: [(Jar, Ledger<PersistentIdentifier>.JarMonth)]) -> JarTransferDraft? {
        guard let (neg, m) = months.min(by: { $0.1.endBalance < $1.1.endBalance }), m.endBalance < 0 else { return nil }
        let source = months.filter { $0.1.endBalance > 0 }.max { $0.1.endBalance < $1.1.endBalance }
        return JarTransferDraft(from: source?.0, to: neg, amount: min(-m.endBalance, source?.1.endBalance ?? -m.endBalance))
    }
}

/// Jar row: icon, name, "% spent" and balance, with a bar.
private struct BudgetJarRow: View {
    let jar: Jar
    let month: Ledger<PersistentIdentifier>.JarMonth

    var body: some View {
        let progress = BudgetLevel.progress(spent: month.spent, budget: month.budget)
        let level = BudgetLevel(balance: month.endBalance, spent: month.spent, budget: month.budget)
        VStack(alignment: .leading, spacing: 8) {
            BudgetRow(title: jar.name, symbol: jar.icon, tint: jar.color) {
                Label(String(localized: "\(Int((progress * 100).rounded()))% spent", table: "Budget"),
                      systemImage: level.symbol ?? "circle.fill")
                    .labelStyle(SpentLabelStyle(showIcon: level.symbol != nil))
                    .foregroundStyle(level == .normal ? Color.inkSecondary : level.text)
            } value: {
                AmountText(month.endBalance, currency: Money.defaultCurrency)
                    .foregroundStyle(month.endBalance < 0 ? Color.danger : Color.ink)
            }
            ProgressView(value: min(progress, 1)).tint(level.fill)
        }
        .padding(.vertical, 2)
    }
}

/// "62% spent", with the warning symbol in front only when the jar needs attention (non-colour cue).
private struct SpentLabelStyle: LabelStyle {
    let showIcon: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            if showIcon { configuration.icon }
            configuration.title
        }
    }
}

/// "Spent" row: amount, share of the budget used, and a bar.
private struct SpentProgress: View {
    let spent: Int
    let budget: Int
    let currency: String

    var body: some View {
        let progress = BudgetLevel.progress(spent: spent, budget: budget)
        VStack(spacing: 8) {
            LabeledContent {
                AmountText(spent, currency: currency).foregroundStyle(Color.ink)
            } label: {
                Text(loc("Spent"))
                Text(verbatim: "\(Int((progress * 100).rounded()))%")
            }
            ProgressView(value: min(progress, 1)).tint(BudgetLevel(progress: progress).fill)
        }
    }
}

extension Date {
    /// "Tháng 11 năm 2026" / "November 2026": the month picker's title, capitalised for the vi format.
    var budgetMonthTitle: String {
        let s = formatted(.dateTime.month(.wide).year())
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}

/// Move money between two jars (a `jarTransfer` txn).
struct JarTransferSheet: View {
    @State var draft: JarTransferDraft
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Jar.order) private var jars: [Jar]
    @Query private var txns: [Txn]
    @State private var note = ""

    var body: some View {
        let ledger = Ledger(txns: txns, wallets: [], jars: jars)
        NavigationStack {
            Form {
                Section {
                    jarPicker(loc("From"), $draft.from, ledger)
                    jarPicker(loc("To"), $draft.to, ledger)
                }
                Section {
                    AmountField(title: loc("Amount"), minor: $draft.amount)
                    TextField(loc("Note"), text: $note)
                } footer: {
                    if draft.from != nil, draft.from == draft.to { Text(loc("Pick two different jars.")).foregroundStyle(Color.danger) }
                }
            }
            .navigationTitle(loc("Move between jars"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(loc("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc("Move")) {
                        guard let from = draft.from, let to = draft.to else { return }
                        BudgetActions.moveBetweenJars(draft.amount, from: from, to: to, note: note, jars: jars, in: context)
                        dismiss()
                    }
                    .disabled(draft.amount <= 0 || draft.from == nil || draft.to == nil || draft.from == draft.to)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func jarPicker(_ title: String, _ selection: Binding<Jar?>, _ ledger: Ledger<PersistentIdentifier>) -> some View {
        Picker(title, selection: selection) {
            Text(loc("Choose")).tag(nil as Jar?)
            ForEach(jars) { j in
                Text("\(j.name) · \(AmountFormat.string(ledger.jarBalance(j.persistentModelID), Money.defaultCurrency, short: true))").tag(j as Jar?)
            }
        }
    }
}

/// One jar: this month's numbers, its categories and the transactions that moved it.
struct JarDetailView: View {
    let jarID: PersistentIdentifier
    let month: Date
    @Query(sort: \Jar.order) private var jars: [Jar]
    @Query(sort: \Txn.date, order: .reverse) private var txns: [Txn]
    @State private var transfer: JarTransferDraft?

    private let currency = Money.defaultCurrency

    var body: some View {
        if let jar = jars.first(where: { $0.persistentModelID == jarID }) {
            content(jar)
        } else {
            ContentUnavailableView(loc("Jar not found"), systemImage: "square.stack.3d.up.slash")
        }
    }

    private func content(_ jar: Jar) -> some View {
        let interval = Calendar.current.dateInterval(of: .month, for: month)!
        let m = Ledger(txns: txns, wallets: [], jars: jars).jarMonth(jarID, in: interval)
        let level = BudgetLevel(balance: m.endBalance, spent: m.spent, budget: m.budget)
        let moves = txns.filter { interval.contains($0.date) }.compactMap { t in delta(t, jar).map { (t, $0) } }
        let categories = (jar.categories ?? []).sorted { $0.order < $1.order }
        return List {
            Section {
                LabeledContent(loc("Balance")) {
                    AmountText(m.endBalance, currency: currency)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(m.endBalance < 0 ? Color.danger : Color.ink)
                }
                SpentProgress(spent: m.spent, budget: m.budget, currency: currency)
                line(loc("Carried over"), m.start)
                line(loc("Added this month"), m.added)
                if level == .over || level == .negative {
                    Label(loc("This jar is over. Move money from another jar to balance it."), systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(Color.danger)
                }
            } header: {
                Text(month.budgetMonthTitle)
            } footer: {
                Text(String(localized: "\(jar.percent)% of each income", table: "Budget"))
            }

            if !categories.isEmpty {
                Section(loc("Categories")) {
                    ForEach(categories) { c in
                        Label { Text(c.name) } icon: { Image(systemName: c.icon).foregroundStyle(c.color) }
                    }
                }
            }

            Section(loc("Transactions")) {
                if moves.isEmpty {
                    Text(loc("Nothing in this jar yet this month.")).foregroundStyle(Color.inkSecondary)
                }
                ForEach(moves, id: \.0.persistentModelID) { t, d in row(t, d) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .navigationTitle(jar.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(loc("Move money"), systemImage: "arrow.left.arrow.right") {
                    transfer = m.endBalance > 0 ? JarTransferDraft(from: jar) : JarTransferDraft(to: jar)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink(value: BudgetRoute.jarSettings(add: false, edit: jarID)) { Label(loc("Edit jar"), systemImage: "pencil") }
                    NavigationLink(value: BudgetRoute.mapping) { Label(loc("Assign categories to jars"), systemImage: "arrow.triangle.branch") }
                } label: {
                    Label(loc("More"), systemImage: "ellipsis")
                }
            }
        }
        .sheet(item: $transfer) { JarTransferSheet(draft: $0) }
    }

    private func line(_ title: String, _ amount: Int) -> some View {
        LabeledContent(title) { AmountText(amount, currency: currency, plus: true).foregroundStyle(Color.ink) }
    }

    /// What `t` did to this jar (− out, + in), or nil if it did not touch it.
    private func delta(_ t: Txn, _ jar: Jar) -> Int? {
        switch t.kind {
        case .expense: t.jar == jar ? -t.amount : nil
        case .income: (t.splits ?? []).first { $0.jar == jar }.map(\.amount)
        case .jarTransfer: t.jar == jar ? -t.amount : t.toJar == jar ? t.amount : nil
        default: nil
        }
    }

    private func row(_ t: Txn, _ d: Int) -> some View {
        let title = !t.note.isEmpty ? t.note : t.kind == .jarTransfer
            ? String(localized: "\(t.jar?.name ?? "") → \(t.toJar?.name ?? "")", table: "Budget")
            : t.category?.name ?? t.kind.title
        return BudgetRow(title: title, symbol: t.kind == .jarTransfer ? "arrow.left.arrow.right" : t.category?.icon ?? "circle.fill",
                         tint: t.category?.color ?? .brandDeep) {
            Text(t.date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(Color.inkSecondary)
        } value: {
            AmountText(d, currency: t.currencyCode, plus: true).foregroundStyle(d > 0 ? Color.income : Color.ink)
        }
    }
}

/// ⋯ → "Spending by jar": this month's spending per jar.
struct JarSpendingChart: View {
    @Query(sort: \Jar.order) private var jars: [Jar]
    @Query private var txns: [Txn]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let month = Calendar.current.dateInterval(of: .month, for: .now)!
        let ledger = Ledger(txns: txns, wallets: [], jars: jars)
        let rows = jars.map { ($0, ledger.jarMonth($0.persistentModelID, in: month).spent) }
        let total = rows.reduce(0) { $0 + $1.1 }
        NavigationStack {
            List {
                Section {
                    DonutChart(slices: rows.map { .init(label: $0.0.name, value: Double($0.1), color: $0.0.color) }) {
                        VStack(spacing: 2) {
                            Text(loc("Spent")).font(.subheadline).foregroundStyle(Color.inkSecondary)
                            AmountText(total, currency: Money.defaultCurrency).font(.headline)
                        }
                    }
                    .frame(maxWidth: 220)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                Section {
                    ForEach(rows, id: \.0.persistentModelID) { jar, spent in
                        BudgetRow(title: jar.name, symbol: jar.icon, tint: jar.color) {
                            AmountText(spent, currency: Money.defaultCurrency)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(loc("Spending by jar"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(loc("Done")) { dismiss() } }
            }
        }
    }
}
