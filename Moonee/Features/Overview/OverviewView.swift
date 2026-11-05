import Charts
import SwiftData
import SwiftUI

/// Overview tab (spec §2), laid out like `asset/ui/Moonee Finance Overview Dashboard.png`.
struct OverviewView: View {
    @Query(sort: \Txn.date, order: .reverse) private var txns: [Txn]
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @Query(sort: \Jar.order) private var jars: [Jar]
    @Query private var assets: [Asset]
    @Query(sort: \Recurring.nextDue) private var bills: [Recurring]
    @AppStorage(Prefs.profileName) private var name = ""
    @AppStorage(Prefs.reminderLevel) private var level = MooneeNote.Level.medium.rawValue
    @AppStorage(Prefs.hideBalances) private var hideBalances = false
    @Environment(\.dynamicTypeSize) private var typeSize
    #if DEBUG
    @Environment(\.modelContext) private var context
    #endif

    private var currency: String { Money.defaultCurrency }

    var body: some View {
        let stats = OverviewStats(txns: txns, wallets: wallets, jars: jars, assets: assets)
        let due = OverviewStats.billsDue(bills)
        let note = MooneeNote.make(level: MooneeNote.Level(rawValue: level) ?? .medium,
                                   jars: stats.jars.map { .init(name: $0.jar.name, balance: $0.month.balance, progress: $0.month.progress) },
                                   bills: due.map { ($0.name, $0.nextDue) }, spentToday: stats.spentToday)
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    if txns.isEmpty {
                        EmptyState(mood: .sleepy, title: String(localized: "No transactions yet", table: "Overview"),
                                   message: String(localized: "Tap + and tell Moonee “lunch 45k” to log your first one.", table: "Overview"))
                            .card()
                    } else {
                        hero(note)
                        spending(stats)
                        jarsCard(stats)
                        let pair = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 14)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                        pair {
                            billsCard(due)
                            // Mockup: bills ≈55% / net worth ≈45%, so full bill amounts fit next to their names.
                            netWorthCard(stats).containerRelativeFrame(.horizontal) { w, _ in typeSize.isAccessibilitySize ? w - 32 : (w - 44) * 0.45 }
                        }.fixedSize(horizontal: false, vertical: true)
                        recent
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(MooneeBackground())
            .toolbar(.hidden, for: .navigationBar)
            .foregroundStyle(Color.ink)
        }
        #if DEBUG
        .task { SampleData.insertIfRequested(context) }
        #endif
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            NavigationLink { TransactionLedgerView() } label: { circleIcon("clock") }
                .accessibilityLabel(Text("Transactions", tableName: "Overview"))
            Spacer()
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(Color.brandYellow)
                    Text(verbatim: "Moonee").font(.title.weight(.bold)).foregroundStyle(Color.brandDeep)
                }
                Text("Your AI money assistant", tableName: "Overview")
                    .font(.footnote.weight(.medium)).foregroundStyle(Color.brandDeep)
                    .padding(.horizontal, 12).padding(.vertical, 3)
                    .background(Color.brandMintSoft, in: .capsule)
            }
            Spacer()
            Menu {
                Toggle(String(localized: "Hide balances", table: "Overview"), systemImage: "eye.slash", isOn: $hideBalances)
            } label: { circleIcon("ellipsis") }
                .accessibilityLabel(Text("More", tableName: "Overview"))
        }
        .padding(.top, 8)
    }

    private func circleIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.title3.weight(.semibold)).foregroundStyle(Color.ink)
            .frame(width: 48, height: 48)
            .background(Color.surface, in: .circle)
            .shadow(color: .brandDeep.opacity(0.08), radius: 8, y: 3)
    }

    private func hero(_ note: MooneeNote) -> some View {
        VStack(spacing: 4) {
            MooneeCharacter(mood: note.mood == .happy ? .greeting : note.mood)
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .background(alignment: .bottom) { Hills().frame(height: 70).opacity(0.35).padding(.horizontal, -16) }
            HStack(alignment: .top, spacing: 10) {
                MooneeAvatar(size: 41)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name.isEmpty ? String(localized: "Hi there! 👋", table: "Overview") : String(localized: "Hi \(name)! 👋", table: "Overview"))
                        .font(.title3.weight(.bold))
                    Text(note.text).font(.subheadline).foregroundStyle(Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.surface.opacity(0.9), in: .rect(cornerRadius: 20))
                .shadow(color: .brandDeep.opacity(0.06), radius: 8, y: 3)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func spending(_ s: OverviewStats) -> some View {
        let halves = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 10))
        return halves {
            VStack(alignment: .leading, spacing: 6) {
                Label { Text("Spent today", tableName: "Overview") } icon: { Image(systemName: "calendar").foregroundStyle(Color.brandDeep) }
                    .font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                AmountText(s.spentToday, currency: currency).font(.title3.weight(.bold))
                if let c = s.todayChange {
                    changeLine(c, upIsGood: false) { Text("vs yesterday", tableName: "Overview") }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize { Divider().frame(height: 60) }
            VStack(alignment: .leading, spacing: 6) {
                Label { Text("Spent this month", tableName: "Overview") } icon: { Image(systemName: "calendar").foregroundStyle(Color.brandDeep) }
                    .font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                AmountText(s.spentMonth, currency: currency).font(.title3.weight(.bold))
                if let p = s.budgetProgress {
                    Text("\(Int((p * 100).rounded()))% of monthly budget", tableName: "Overview")
                        .font(.caption).foregroundStyle(Color.inkSecondary).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let p = s.budgetProgress {
                ProgressRing(progress: p, lineWidth: 7).frame(width: 66)
            }
        }
        .card(padding: 14)
    }

    /// "▼ -42% vs yesterday": arrow + sign, so colour is never the only cue.
    private func changeLine(_ change: Int, upIsGood: Bool, @ViewBuilder suffix: () -> Text) -> some View {
        let good = change == 0 || (change > 0) == upIsGood
        return HStack(spacing: 3) {
            Image(systemName: change > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").imageScale(.small)
            Text(verbatim: "\(change > 0 ? "+" : "")\(change)%").fontWeight(.semibold).monospacedDigit()
            suffix().foregroundStyle(Color.inkSecondary)
        }
        .font(.caption2)
        .foregroundStyle(good ? Color.brandDeep : Color.warningText)
        .lineLimit(1).minimumScaleFactor(0.7)
    }

    private func sectionTitle(_ title: Text, symbol: String) -> some View {
        HStack(spacing: 8) {
            IconBadge(symbol: symbol, color: .brandDeep, size: 30)
            title.font(.headline)
        }
    }

    private var seeAll: some View {
        HStack(spacing: 2) { Text("See all", tableName: "Overview"); Image(systemName: "chevron.right") }
            .font(.footnote.weight(.semibold)).foregroundStyle(Color.brandDeep)
            .frame(minHeight: 44).contentShape(.rect)
    }

    private func jarsCard(_ s: OverviewStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle(Text("Jar balances", tableName: "Overview"), symbol: "square.stack.3d.up.fill")
                Spacer()
                NavigationLink { JarsListView(jars: s.jars) } label: { seeAll }
            }
            // Mockup: the first 4 jars fill the card in equal columns; the rest are behind "See all".
            let columns = typeSize.isAccessibilitySize ? 2 : 4
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(s.jars.prefix(4)) { row in
                    JarCard(name: row.jar.name, symbol: row.jar.icon, color: row.jar.color, balance: row.month.balance,
                            spent: row.month.spent, budget: row.month.budget, currency: currency, layout: .tile)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .card(padding: 14)
    }

    private func billsCard(_ due: [Recurring]) -> some View {
        NavigationLink { BillsListView() } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "bell").foregroundStyle(Color.brandDeep)
                    Text("Bills due soon", tableName: "Overview").font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                    if !due.isEmpty {
                        Text(verbatim: "\(due.count)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .frame(minWidth: 18, minHeight: 18).background(Color.danger, in: .circle)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.inkSecondary)
                }
                if due.isEmpty {
                    Text("Nothing due in the next 7 days.", tableName: "Overview").font(.footnote).foregroundStyle(Color.inkSecondary)
                }
                ForEach(due.prefix(2)) { b in
                    let status = BillStatus(due: b.nextDue, paid: false)
                    HStack(spacing: 8) {
                        IconBadge(symbol: b.category?.icon ?? "doc.text", color: .brandDeep, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(b.name).font(.caption.weight(.semibold)).lineLimit(1)
                            Group {
                                if status.urgent { status.label } else { Text("Due \(OverviewView.dayMonth(b.nextDue))", tableName: "Overview") }
                            }
                            .font(.caption2).foregroundStyle(status.color).lineLimit(1)
                        }
                        .layoutPriority(1) // the amount shrinks before the name/date truncate
                        Spacer(minLength: 4)
                        AmountText(b.amount, currency: b.currencyCode).font(.caption.weight(.semibold))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .card(padding: 14)
        }
        .buttonStyle(.plain)
    }

    /// "08/11" as in the mockup (ICU gives "08-11" in vi).
    static func dayMonth(_ d: Date) -> String {
        d.formatted(.dateTime.day(.twoDigits).month(.twoDigits)).replacingOccurrences(of: "-", with: "/")
    }

    private func netWorthCard(_ s: OverviewStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "leaf").foregroundStyle(Color.brandDeep)
                Text("Net worth", tableName: "Overview").font(.subheadline.weight(.semibold))
            }
            AmountText(s.netWorth, currency: currency).font(.title3.weight(.bold))
            if let c = s.netWorthChange {
                changeLine(c, upIsGood: true) { Text("vs last month", tableName: "Overview") }
            }
            Spacer(minLength: 0)
            Chart(Array(s.netWorthTrend.enumerated()), id: \.offset) { i, v in
                let (m, nw) = ("month", "net worth") // plain Strings: chart labels stay out of the String Catalog
                AreaMark(x: .value(m, i), yStart: .value(nw, s.netWorthTrend.min() ?? 0), yEnd: .value(nw, v))
                    .foregroundStyle(LinearGradient(colors: [.brandPrimary.opacity(0.35), .brandPrimary.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value(m, i), y: .value(nw, v)).foregroundStyle(Color.brandPrimary).interpolationMethod(.catmullRom)
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 40)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 14)
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionTitle(Text("Recent transactions", tableName: "Overview"), symbol: "arrow.left.arrow.right")
                Spacer()
                NavigationLink { TransactionLedgerView() } label: { seeAll }
            }
            .padding(.bottom, 4)
            let recent = Array(txns.prefix(3))
            ForEach(recent) { t in
                TxnRow(txn: t, showDay: true)
                if t != recent.last { Divider().padding(.leading, 44) }
            }
        }
        .card(padding: 14)
    }
}

// MARK: - Shared rows

/// One transaction: icon, title, "Today · Cash wallet", signed amount.
struct TxnRow: View {
    let txn: Txn
    /// Overview shows "Today"; the ledger is already grouped by day and shows the category instead.
    var showDay = false

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: txn.category?.icon ?? txn.kind.symbol, color: txn.category?.color ?? .brandDeep, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(txn.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(Color.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            let flow = txn.flow
            AmountText(flow == 0 ? txn.amount : flow, currency: txn.currencyCode, plus: flow != 0)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(flow > 0 ? Color.income : Color.ink)
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let day = Calendar.current.isDateInToday(txn.date) ? String(localized: "Today", table: "Overview")
            : Calendar.current.isDateInYesterday(txn.date) ? String(localized: "Yesterday", table: "Overview")
            : txn.date.formatted(.dateTime.day().month())
        let from = txn.kind == .jarTransfer ? txn.jar?.name : txn.wallet?.name
        let to = txn.kind == .jarTransfer ? txn.toJar?.name : txn.toWallet?.name
        let place = [from, to].compactMap { $0 }.joined(separator: " → ")
        let parts = showDay ? [day, place] : [txn.category?.name ?? txn.kind.title, place]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private extension Txn {
    /// Note, else category, else kind ("Transfer").
    var title: String { !note.isEmpty ? note : category?.name ?? kind.title }

    /// What it did to my money: out < 0, in > 0, a move between my own wallets/jars = 0.
    var flow: Int {
        switch kind {
        case .expense, .lend: -amount
        case .income, .borrow: amount
        case .repay: debt?.direction == .lent ? amount : -amount
        case .transfer, .jarTransfer: 0
        }
    }
}

private extension TxKind {
    var symbol: String {
        switch self {
        case .expense: "cart.fill"
        case .income: "arrow.down.circle.fill"
        case .transfer: "arrow.left.arrow.right"
        case .jarTransfer: "arrow.triangle.swap"
        case .lend: "arrow.up.forward.circle.fill"
        case .borrow: "arrow.down.backward.circle.fill"
        case .repay: "arrow.uturn.backward.circle.fill"
        }
    }
}

/// Every bill, soonest first. Read-only: the Budget tab (S6) owns adding, editing and "Mark paid".
struct BillsListView: View {
    @Query(sort: \Recurring.nextDue) private var bills: [Recurring]

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if bills.isEmpty {
                    EmptyState(mood: .sleepy, title: String(localized: "No bills yet", table: "Overview"),
                               message: String(localized: "Add your regular bills in Budget and Moonee will remind you.", table: "Overview"))
                }
                ForEach(bills) { b in
                    BillCard(name: b.name, symbol: b.category?.icon ?? "doc.text", amount: b.amount, currency: b.currencyCode,
                             due: b.nextDue, estimate: b.isEstimate)
                }
            }
            .padding(16)
        }
        .background(MooneeBackground())
        .navigationTitle(String(localized: "Bills", table: "Overview"))
    }
}

/// Every jar as a row (Overview → Jar balances → See all). Read-only; the Budget tab (S6) owns jar editing.
struct JarsListView: View {
    let jars: [OverviewStats.JarRow]

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(jars) { row in
                    JarCard(name: row.jar.name, symbol: row.jar.icon, color: row.jar.color, balance: row.month.balance,
                            spent: row.month.spent, budget: row.month.budget, currency: Money.defaultCurrency, subtitle: "\(row.jar.percent)%")
                }
            }
            .padding(16)
        }
        .background(MooneeBackground())
        .navigationTitle(String(localized: "Jar balances", table: "Overview"))
    }
}
