import SwiftData
import SwiftUI

/// Budget tab (spec §4.1–4.3): one inset-grouped list — jars, wallets (with credit cards), recurring bills.
/// Adding things lives in the + menu; per-row actions are swipes and context menus.
struct BudgetView: View {
    @State private var path = NavigationPath()
    @State private var sheet: BudgetSheet?
    @State private var month = Calendar.current.dateInterval(of: .month, for: .now)!
    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationStack(path: $path) {
            List {
                AdvisorSection(sheet: $sheet)
                JarsSection(month: $month, sheet: $sheet, path: $path)
                WalletsSection(sheet: $sheet)
                BillsSection(sheet: $sheet)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(MooneeBackground())
            .navigationTitle(loc("Budget"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(loc("Move between jars"), systemImage: "arrow.left.arrow.right") { sheet = .transfer(JarTransferDraft()) }
                        Button(loc("Buy an asset or save"), systemImage: "chart.line.uptrend.xyaxis") { sheet = .setAside(.buy) }
                        Button(loc("Add jar"), systemImage: "square.stack.3d.up") { path.append(BudgetRoute.jarSettings(add: true, edit: nil)) }
                        Button(loc("Add wallet"), systemImage: "wallet.bifold") { sheet = .wallet(nil) }
                        Button(loc("Add bill"), systemImage: "calendar.badge.plus") { sheet = .bill(nil) }
                    } label: {
                        Label(loc("Add"), systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(loc("Spending by jar"), systemImage: "chart.pie") { sheet = .chart }
                        Button(loc("Edit income split"), systemImage: "percent") { path.append(BudgetRoute.jarSettings(add: false, edit: nil)) }
                        Button(loc("Assign categories to jars"), systemImage: "arrow.triangle.branch") { path.append(BudgetRoute.mapping) }
                        Button(loc("Reminders"), systemImage: "bell") { path.append(BudgetRoute.reminders) }
                        Button(loc("Moonee's help"), systemImage: "lightbulb") { path.append(BudgetRoute.advisor) }
                    } label: {
                        Label(loc("More"), systemImage: "ellipsis")
                    }
                }
            }
            .navigationDestination(for: BudgetRoute.self) { $0.view }
            .sheet(item: $sheet) { $0.view }
        }
        .task {
            #if DEBUG
            BudgetDemo.seedIfRequested(context)
            #endif
            BudgetActions.catchUpIncome(in: context) // a salary logged in chat moves on to the next payday
            Autopilot.run(context)
        }
    }
}

/// Screens pushed from the Budget tab.
enum BudgetRoute: Hashable {
    case jar(PersistentIdentifier, month: Date)
    case jarSettings(add: Bool, edit: PersistentIdentifier?)
    case mapping
    case reminders
    case advisor

    @ViewBuilder var view: some View {
        switch self {
        case .jar(let id, let month): JarDetailView(jarID: id, month: month)
        case .jarSettings(let add, let edit): JarSettingsView(startAdding: add, editJar: edit)
        case .mapping: JarMappingView()
        case .reminders: ReminderSettingsView()
        case .advisor: AdvisorSettingsView()
        }
    }
}

/// Every sheet the Budget list opens, presented once at the list (not from rows, which may scroll away).
enum BudgetSheet: Identifiable {
    case transfer(JarTransferDraft)
    case wallet(Wallet?)
    case payCard(Wallet, debt: Int)
    case bill(Recurring?)
    case payBill(Recurring)
    case setAside(SetAsideSheet.Mode)
    case chart

    var id: String {
        switch self {
        case .transfer(let d): "transfer.\(d.id)"
        case .wallet(let w): "wallet.\(w.map { "\($0.persistentModelID)" } ?? "new")"
        case .payCard(let w, _): "pay.\(w.persistentModelID)"
        case .bill(let b): "bill.\(b.map { "\($0.persistentModelID)" } ?? "new")"
        case .payBill(let b): "paid.\(b.persistentModelID)"
        case .setAside(let m): "setAside.\(m.rawValue)"
        case .chart: "chart"
        }
    }

    @ViewBuilder var view: some View {
        switch self {
        case .transfer(let d): JarTransferSheet(draft: d)
        case .wallet(let w): WalletForm(wallet: w)
        case .payCard(let w, let debt): PayCardSheet(card: w, debt: debt)
        case .bill(let b): RecurringForm(bill: b)
        case .payBill(let b): PayBillSheet(bill: b)
        case .setAside(let m): SetAsideSheet(mode: m)
        case .chart: JarSpendingChart()
        }
    }
}

/// List row: tinted SF Symbol, title, optional second line, trailing value.
struct BudgetRow<Subtitle: View, Value: View>: View {
    let title: String
    let symbol: String
    var tint: Color = .brandDeep
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var value: Value

    var body: some View {
        LabeledContent {
            value.foregroundStyle(Color.ink).monospacedDigit()
        } label: {
            Label {
                Text(title).foregroundStyle(Color.ink)
                subtitle.font(.subheadline)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
        }
    }
}

extension BudgetRow where Subtitle == EmptyView {
    init(title: String, symbol: String, tint: Color = .brandDeep, @ViewBuilder value: () -> Value) {
        self.init(title: title, symbol: symbol, tint: tint, subtitle: { EmptyView() }, value: value)
    }
}

/// Money typed in the major unit ("45000", "12.50"), stored as minor units.
/// Parsed on every keystroke: a `value:format:` field only commits when editing ends, so tapping Save while
/// typing lost the last digit (2000000 saved as 200000).
struct AmountField: View {
    let title: String
    @Binding var minor: Int
    var currency = Money.defaultCurrency
    @State private var text = ""

    var body: some View {
        LabeledContent(title) {
            TextField(AmountFormat.string(0, currency), text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .onChange(of: text) { _, t in minor = Money(major: (try? Decimal(t, format: .number)) ?? 0, currency).minor }
                .onAppear { if minor != 0, text.isEmpty { text = Money(minor, currency).major.formatted(.number) } }
        }
    }
}
