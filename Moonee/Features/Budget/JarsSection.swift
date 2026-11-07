import SwiftData
import SwiftUI

/// Prefill for the "Move between jars" sheet.
struct JarTransferDraft: Identifiable {
    let id = UUID()
    var from: Jar?
    var to: Jar?
    var amount = 0
}

/// Jars section of the Budget list (spec §4.1): one row per jar for the month shown, with "X/day" left this month.
/// The month's numbers are `BudgetFacts`, the same struct the assistant reads.
struct JarsSection: View {
    let month: DateInterval
    @Binding var sheet: BudgetSheet?
    @Binding var path: NavigationPath
    @Query(sort: \Jar.order) private var jars: [Jar]
    @Query private var txns: [Txn]
    @Query private var wallets: [Wallet]
    @Query(sort: \Recurring.nextDue) private var recurrings: [Recurring]

    var body: some View {
        let ledger = Ledger(txns: txns, wallets: wallets, jars: jars)
        let months = jars.map { ($0, ledger.jarMonth($0.persistentModelID, in: month)) }
        let advisor = BudgetFacts(txns: txns, wallets: wallets, jars: jars, recurrings: recurrings, month: month).advisor
        let isNow = month.contains(.now)
        Section {
            ForEach(months, id: \.0.persistentModelID) { jar, m in
                NavigationLink(value: BudgetRoute.jar(jar.persistentModelID, month: month.start)) {
                    BudgetJarRow(jar: jar, month: m, perDay: isNow ? advisor.perDay(m.endBalance) : 0)
                }
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

    /// Swipe "Move money": a jar with money gives, a jar without receives.
    private func draft(for jar: Jar, _ m: Ledger<PersistentIdentifier>.JarMonth) -> JarTransferDraft {
        m.endBalance > 0 ? JarTransferDraft(from: jar) : JarTransferDraft(to: jar)
    }
}

/// Jar row: icon, name, "% spent" and balance, with a bar.
private struct BudgetJarRow: View {
    let jar: Jar
    let month: Ledger<PersistentIdentifier>.JarMonth
    /// "50k/day" left this month; 0 hides it.
    var perDay = 0
    @Environment(\.balanceHidden) private var hidden

    var body: some View {
        let progress = BudgetLevel.progress(spent: month.spent, budget: month.budget)
        let level = BudgetLevel(balance: month.endBalance, spent: month.spent, budget: month.budget)
        VStack(alignment: .leading, spacing: 8) {
            BudgetRow(title: jar.name, symbol: jar.icon, tint: jar.color) {
                let spent = String(localized: "\(Int((progress * 100).rounded()))% spent", table: "Budget")
                let daily = perDay > 0
                    ? " · " + String(localized: "\(hidden ? AmountFormat.mask : AmountFormat.string(perDay, Money.defaultCurrency, short: true))/day left", table: "Budget")
                    : ""
                Label(spent + daily, systemImage: level.symbol ?? "circle.fill")
                    .labelStyle(SpentLabelStyle(showIcon: level.symbol != nil))
                    .foregroundStyle(level == .normal ? Color.inkSecondary : level.text)
            } value: {
                AmountText(month.endBalance, currency: Money.defaultCurrency)
                    .foregroundStyle(month.endBalance < 0 ? Color.danger : Color.ink)
            }
            GrowBar(progress: progress, color: level == .normal ? jar.color : level.fill)
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
            GrowBar(progress: progress, color: BudgetLevel(progress: progress).fill)
        }
    }
}

/// Capsule progress bar that grows in from the left, in the jar's colour.
private struct GrowBar: View {
    let progress: Double
    let color: Color
    @State private var grow = 0.0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.track)
                Capsule().fill(color.gradient)
                    .frame(width: max(progress > 0 ? 6 : 0, geo.size.width * min(max(progress, 0), 1) * grow))
            }
        }
        .frame(height: 6)
        .growIn($grow)
        .accessibilityHidden(true)
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
    @State private var limitFor: Category?
    @Environment(\.balanceHidden) private var hidden

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
        let isNow = interval.contains(.now)
        // Only the clock and currency matter for "per day" and the forecast.
        let clock = BudgetAdvisor(.init(jars: [], budgetBalance: 0, unallocated: 0, now: .now, currency: currency))
        let moves = txns.filter { interval.contains($0.date) }.compactMap { t in delta(t, jar).map { (t, $0) } }
        let categories = BudgetFacts.CategoryLine.categories(of: jar)
        let spent = BudgetFacts.CategoryLine.spent(txns, in: interval)
        let limits = categories.reduce(0) { $0 + ($1.monthlyLimit ?? 0) }
        return List {
            Section {
                LabeledContent(loc("Balance")) {
                    AmountText(m.endBalance, currency: currency)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(m.endBalance < 0 ? Color.danger : Color.ink)
                }
                if isNow, case let daily = clock.perDay(m.endBalance), daily > 0 {
                    LabeledContent(loc("Per day until month end")) { AmountText(daily, currency: currency).foregroundStyle(Color.brandDeep) }
                }
                SpentProgress(spent: m.spent, budget: m.budget, currency: currency)
                if isNow, let forecast = clock.monthEndForecast(spent: m.spent) {
                    Label {
                        Text(String(localized: "At this pace you'll spend about \(hidden ? AmountFormat.mask : AmountFormat.string(forecast, currency)) by month end.", table: "Budget"))
                    } icon: {
                        Image(systemName: forecast > m.budget ? "exclamationmark.triangle.fill" : "chart.line.uptrend.xyaxis")
                    }
                    .font(.subheadline)
                    .foregroundStyle(forecast > m.budget ? Color.danger : Color.inkSecondary)
                }
                LabeledContent(loc("Available this month")) { AmountText(m.budget, currency: currency).foregroundStyle(Color.ink) }
                line(loc("Carried over"), m.start)
                line(loc("Added this month"), m.added)
                if m.setAside != 0 { line(loc("Set aside"), -m.setAside) }
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
                Section {
                    ForEach(categories) { c in
                        Button { limitFor = c } label: { CategoryLimitRow(category: c, line: .init(c, spent: spent)) }
                            .accessibilityHint(loc("Set a monthly limit"))
                    }
                } header: {
                    Text(loc("Category limits"))
                } footer: {
                    // Same rule as BudgetFacts.JarLine.limitsOverBudget.
                    if limits > max(m.budget, 0) {
                        Label(String(localized: "Limits add up to \(hidden ? AmountFormat.mask : AmountFormat.string(limits, currency)), more than this jar has this month (\(hidden ? AmountFormat.mask : AmountFormat.string(m.budget, currency))).", table: "Budget"),
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.warningText)
                    } else {
                        Text(loc("Tap a category to set a monthly limit. A limit holds no money: the jar does."))
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
        .sheet(item: $limitFor) { CategoryLimitSheet(category: $0, spent: spent[$0.persistentModelID] ?? 0) }
    }

    private func line(_ title: String, _ amount: Int) -> some View {
        LabeledContent(title) { AmountText(amount, currency: currency, plus: true).foregroundStyle(Color.ink) }
    }

    /// What `t` did to this jar (− out, + in), or nil if it did not touch it.
    private func delta(_ t: Txn, _ jar: Jar) -> Int? {
        switch t.kind {
        case .expense: t.jar == jar ? -t.amount : nil
        case .income: (t.splits ?? []).first { $0.jar == jar }.map(\.amount)
        case .jarTransfer: t.jar == jar ? -t.amount : t.toJar == jar ? t.amount : (t.splits ?? []).first { $0.jar == jar }.map(\.amount)
        case .transfer: t.jar == jar ? -t.amount : nil // set aside: an asset bought, a savings deposit
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

/// A category in the jar detail: with a limit, spent of the limit, what is left and a bar (80% / 100% colours like jars).
private struct CategoryLimitRow: View {
    let category: Category
    let line: BudgetFacts.CategoryLine
    @Environment(\.balanceHidden) private var hidden

    var body: some View {
        let short = { (v: Int) in hidden ? AmountFormat.mask : AmountFormat.string(v, Money.defaultCurrency, short: true) }
        VStack(alignment: .leading, spacing: 8) {
            BudgetRow(title: category.name, symbol: category.icon, tint: category.color) {
                if let limit = line.limit, let level = line.level {
                    Label(String(localized: "\(short(line.spent)) of \(short(limit)) limit", table: "Budget"), systemImage: level.symbol ?? "circle.fill")
                        .labelStyle(SpentLabelStyle(showIcon: level.symbol != nil))
                        .foregroundStyle(level == .normal ? Color.inkSecondary : level.text)
                } else if line.spent > 0 {
                    Text(String(localized: "Spent \(short(line.spent))", table: "Budget")).foregroundStyle(Color.inkSecondary)
                }
            } value: {
                if let left = line.left {
                    AmountText(left, currency: Money.defaultCurrency).foregroundStyle(left < 0 ? Color.danger : Color.ink)
                } else {
                    Text(loc("Set limit")).foregroundStyle(Color.brandDeep)
                }
            }
            if let limit = line.limit, let level = line.level {
                GrowBar(progress: BudgetLevel.progress(spent: line.spent, budget: limit), color: level == .normal ? category.color : level.fill)
            }
        }
        .padding(.vertical, 2)
    }
}

/// "Set limit": a monthly spending cap for one category, inside its jar (spec P1-1). Month only.
struct CategoryLimitSheet: View {
    let category: Category
    let spent: Int
    @State private var amount: Int
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    init(category: Category, spent: Int) {
        self.category = category
        self.spent = spent
        _amount = State(initialValue: category.monthlyLimit ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AmountField(title: loc("Monthly limit"), minor: $amount)
                } footer: {
                    Text(String(localized: "Spent this month: \(AmountFormat.string(spent, Money.defaultCurrency)). Moonee reminds you at 80% and 100%.", table: "Budget"))
                }
                if category.monthlyLimit != nil {
                    Section {
                        Button(loc("Remove limit"), role: .destructive) { save(nil) }
                    }
                }
            }
            .navigationTitle(category.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(loc("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(loc("Save")) { save(amount) }.disabled(amount <= 0) }
            }
        }
        .presentationDetents([.medium])
    }

    private func save(_ limit: Int?) {
        category.monthlyLimit = limit
        try? context.save()
        dismiss()
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
