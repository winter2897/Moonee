import SwiftData
import SwiftUI

/// Prefill for the "Move between jars" sheet.
struct JarTransferDraft: Identifiable {
    let id = UUID()
    var from: Jar?
    var to: Jar?
    var amount = 0
}

/// Jars segment: month total, jar cards, negative-jar fix, actions (spec §4.1).
struct JarsSection: View {
    @Query(sort: \Jar.order) private var jars: [Jar]
    @Query private var txns: [Txn]
    @State private var month = Calendar.current.dateInterval(of: .month, for: .now)!
    @State private var transfer: JarTransferDraft?

    private let currency = Money.defaultCurrency

    var body: some View {
        let ledger = Ledger(txns: txns, wallets: [], jars: jars)
        let months = jars.map { ($0, ledger.jarMonth($0.persistentModelID, in: month)) }
        VStack(spacing: 12) {
            totalCard(months.map(\.1))
            if let fix = suggestedFix(months) { negativeBanner(fix) }

            BudgetSectionHeader(title: String(localized: "Jars (\(jars.count))", table: "Budget")) {
                NavigationLink(value: BudgetRoute.jarSettings(add: false, edit: nil)) {
                    HStack(spacing: 4) {
                        Text(String(localized: "Income split: \(jars.map { "\($0.percent)" }.joined(separator: " / "))", table: "Budget"))
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                }
            }

            VStack(spacing: 0) {
                ForEach(months, id: \.0.persistentModelID) { jar, m in
                    if jar.persistentModelID != months.first?.0.persistentModelID { Divider().padding(.leading, 56) }
                    NavigationLink(value: BudgetRoute.jar(jar.persistentModelID, month: month.start)) {
                        JarCard(name: jar.name, symbol: jar.icon, color: jar.color, balance: m.endBalance, spent: m.spent,
                                budget: m.budget, currency: currency, subtitle: "\(jar.percent)%")
                    }
                    .buttonStyle(.plain)
                }
            }
            .card(padding: 0) // S2: JarCard rows have no background of their own (UI review B-2)

            HStack(spacing: 8) {
                Button { transfer = JarTransferDraft() } label: { ActionTile(title: loc("Move between jars"), symbol: "arrow.left.arrow.right") }
                NavigationLink(value: BudgetRoute.jarSettings(add: true, edit: nil)) { ActionTile(title: loc("Add jar"), symbol: "plus") }
                NavigationLink(value: BudgetRoute.jarSettings(add: false, edit: nil)) { ActionTile(title: loc("Edit split"), symbol: "pencil") }
                NavigationLink(value: BudgetRoute.mapping) { ActionTile(title: loc("Manage categories"), symbol: "slider.horizontal.3") }
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .sheet(item: $transfer) { JarTransferSheet(draft: $0) }
    }

    private func totalCard(_ months: [Ledger<PersistentIdentifier>.JarMonth]) -> some View {
        let budget = months.reduce(0) { $0 + $1.budget }, spent = months.reduce(0) { $0 + $1.spent }
        let progress = BudgetLevel.progress(spent: spent, budget: budget)
        let level = BudgetLevel(progress: progress)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(loc("Total budget this month")).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                monthPicker
            }
            AmountText(budget, currency: currency).font(.system(size: 34, weight: .bold, design: .rounded))
            HStack(spacing: 4) {
                Text(loc("Spent")).foregroundStyle(Color.inkSecondary)
                AmountText(spent, currency: currency).fontWeight(.semibold)
                Text(verbatim: "·").foregroundStyle(Color.inkSecondary)
                Text(loc("Left")).foregroundStyle(Color.inkSecondary)
                AmountText(budget - spent, currency: currency).fontWeight(.semibold)
            }
            .font(.subheadline)
            HStack(spacing: 12) {
                MooneeProgressBar(progress: progress, tint: level.fill, height: 12)
                Text("\(Int((progress * 100).rounded()))%").font(.headline).monospacedDigit().foregroundStyle(level.text)
            }
        }
        .card(padding: 18)
    }

    private var monthPicker: some View {
        let cal = Calendar.current
        let recent = (0..<12).compactMap { cal.date(byAdding: .month, value: -$0, to: .now).flatMap { cal.dateInterval(of: .month, for: $0) } }
        return Menu {
            Picker(selection: $month) {
                ForEach(recent, id: \.start) { Text($0.start.formatted(.dateTime.month(.wide).year())).tag($0) }
            } label: { EmptyView() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar").foregroundStyle(Color.brandDeep)
                Text(month.start.formatted(.dateTime.month(.wide).year())).lineLimit(1).fixedSize()
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.surface, in: .capsule)
            .overlay(Capsule().stroke(Color.track))
        }
    }

    /// Spec §4.1: a negative jar gets a warning and a suggested transfer from the jar with the most money.
    private func suggestedFix(_ months: [(Jar, Ledger<PersistentIdentifier>.JarMonth)]) -> JarTransferDraft? {
        guard let (neg, m) = months.min(by: { $0.1.endBalance < $1.1.endBalance }), m.endBalance < 0 else { return nil }
        let source = months.filter { $0.1.endBalance > 0 }.max { $0.1.endBalance < $1.1.endBalance }
        return JarTransferDraft(from: source?.0, to: neg, amount: min(-m.endBalance, source?.1.endBalance ?? -m.endBalance))
    }

    private func negativeBanner(_ fix: JarTransferDraft) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.danger).font(.title3)
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "\(fix.to?.name ?? "") is below zero", table: "Budget")).font(.subheadline.weight(.semibold))
                if let from = fix.from {
                    Text(String(localized: "Move \(AmountFormat.string(fix.amount, currency)) from \(from.name) to cover it?", table: "Budget"))
                        .font(.footnote).foregroundStyle(Color.inkSecondary)
                    Button(loc("Move money")) { transfer = fix }
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).frame(minHeight: 36)
                        .foregroundStyle(.white)
                        .background(LinearGradient.brand, in: .capsule)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.danger.opacity(0.08), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.danger.opacity(0.25)))
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
        return ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 12) {
                    HStack(spacing: 14) {
                        IconBadge(symbol: jar.icon, color: jar.color, size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "\(jar.percent)% of each income", table: "Budget")).font(.footnote).foregroundStyle(Color.inkSecondary)
                            AmountText(m.endBalance, currency: currency)
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(m.endBalance < 0 ? Color.danger : Color.ink)
                        }
                        Spacer()
                        ProgressRing(progress: m.budget > 0 || m.spent > 0 ? BudgetLevel.progress(spent: m.spent, budget: m.budget) : 0, lineWidth: 8)
                            .frame(width: 76)
                    }
                    Divider()
                    line(loc("Carried over"), m.start)
                    line(loc("Added this month"), m.added)
                    line(loc("Spent this month"), -m.spent)
                    if level == .over || level == .negative {
                        Label(loc("This jar is over. Move money from another jar to balance it."), systemImage: "exclamationmark.circle.fill")
                            .font(.footnote).foregroundStyle(Color.danger).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .card()

                Button { transfer = JarTransferDraft(from: m.endBalance > 0 ? jar : nil, to: m.endBalance > 0 ? nil : jar) } label: {
                    Label(loc("Move money"), systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(MooneeButtonStyle())

                let categories = (jar.categories ?? []).sorted { $0.order < $1.order }
                if !categories.isEmpty {
                    BudgetSectionHeader(title: loc("Categories")) {
                        NavigationLink(loc("Edit"), value: BudgetRoute.mapping)
                    }
                    FlowChips(items: categories.map { ($0.name, $0.icon, $0.color) })
                }

                BudgetSectionHeader(title: loc("This month")) { EmptyView() }
                if moves.isEmpty {
                    Text(loc("Nothing in this jar yet this month.")).font(.subheadline).foregroundStyle(Color.inkSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                } else {
                    VStack(spacing: 0) {
                        ForEach(moves, id: \.0.persistentModelID) { t, d in
                            row(t, d)
                            if t != moves.last?.0 { Divider().padding(.leading, 52) }
                        }
                    }
                    .card(padding: 12)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(MooneeBackground())
        .foregroundStyle(Color.ink)
        .navigationTitle(jar.name)
        .toolbar {
            NavigationLink(value: BudgetRoute.jarSettings(add: false, edit: jarID)) { Text(loc("Edit")) }
        }
        .sheet(item: $transfer) { JarTransferSheet(draft: $0) }
    }

    private func line(_ title: String, _ amount: Int) -> some View {
        HStack {
            Text(title).foregroundStyle(Color.inkSecondary)
            Spacer()
            AmountText(amount, currency: currency, plus: true).fontWeight(.semibold)
        }
        .font(.subheadline)
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
        return HStack(spacing: 12) {
            IconBadge(symbol: t.kind == .jarTransfer ? "arrow.left.arrow.right" : t.category?.icon ?? "circle.fill",
                      color: t.category?.color ?? .brandDeep, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(t.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(Color.inkSecondary)
            }
            Spacer()
            AmountText(d, currency: t.currencyCode, plus: true)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(d > 0 ? Color.income : Color.expense)
        }
        .padding(.vertical, 8)
    }
}

/// Wrapping row of small category chips.
struct FlowChips: View {
    let items: [(String, String, Color)]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.0) { name, icon, color in
                Label(name, systemImage: icon)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(color.opacity(0.14), in: .capsule)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Minimal wrapping layout (no Swift package needed).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: .unspecified)
                x += s.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + s.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + s.width
            r.height = max(r.height, s.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}
