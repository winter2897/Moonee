import SwiftData
import SwiftUI

/// Budget tab (spec §4.1–4.3): jars, wallets, recurring bills, as in the Budget mockup.
struct BudgetView: View {
    enum Segment: String, Hashable { case jars, wallets, bills }

    #if DEBUG
    // Screenshots: launch with `-budgetSegment wallets`.
    @State private var segment = UserDefaults.standard.string(forKey: "budgetSegment").flatMap(Segment.init) ?? .jars
    #else
    @State private var segment = Segment.jars
    #endif
    @State private var showChart = false
    #if DEBUG
    @Environment(\.modelContext) private var context
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    segments
                    switch segment {
                    case .jars: JarsSection()
                    case .wallets: WalletsSection()
                    case .bills: BillsSection()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(MooneeBackground())
            .foregroundStyle(Color.ink)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: BudgetRoute.self) { $0.view }
            .sheet(isPresented: $showChart) { JarSpendingChart() }
        }
        #if DEBUG
        .task { BudgetDemo.seedIfRequested(context) }
        #endif
    }

    private var header: some View {
        VStack(spacing: 6) {
            MooneeHeader(Text(loc("Budget & jars"))) {
                Button { showChart = true } label: { HeaderCircle("chart.bar") }
                    .accessibilityLabel(loc("Spending by jar"))
            } trailing: {
                Menu {
                    NavigationLink(value: BudgetRoute.reminders) { Label(loc("Reminders"), systemImage: "bell") }
                    NavigationLink(value: BudgetRoute.jarSettings(add: false, edit: nil)) { Label(loc("Customize jars"), systemImage: "square.stack.3d.up") }
                    NavigationLink(value: BudgetRoute.mapping) { Label(loc("Assign categories to jars"), systemImage: "arrow.triangle.branch") }
                } label: { HeaderCircle("ellipsis") }
                    .accessibilityLabel(loc("More"))
            }
            MooneeHero(mood: .happy, compact: true)
        }
        .padding(.top, 8)
    }

    private var segments: some View {
        // Long labels (vi: "Định kỳ & Hoá đơn") drop the icons, then shrink, before they get cut.
        ViewThatFits(in: .horizontal) {
            pills(icons: true)
            pills(icons: false)
            ScrollView(.horizontal, showsIndicators: false) { pills(icons: true) } // large Dynamic Type: scroll, never truncate
        }
        .padding(4)
        .background(Color.surface.opacity(0.7), in: .capsule)
    }

    private func pills(icons: Bool) -> some View {
        HStack(spacing: 0) {
            pill(.jars, loc("Jars"), icons ? "square.stack.3d.up" : nil)
            Spacer(minLength: 2)
            pill(.wallets, loc("Wallets / Accounts"), icons ? "wallet.bifold" : nil)
            Spacer(minLength: 2)
            pill(.bills, loc("Recurring & Bills"), icons ? "calendar" : nil)
        }
        .font(.chip)
    }

    private func pill(_ value: Segment, _ title: String, _ symbol: String?) -> some View {
        Button { withAnimation(.snappy) { segment = value } } label: {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(title).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(minHeight: 36)
            .foregroundStyle(segment == value ? .white : Color.ink)
            .background { if segment == value { Capsule().fill(LinearGradient.brand) } }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(segment == value ? .isSelected : [])
    }
}

/// Screens pushed from the Budget tab.
enum BudgetRoute: Hashable {
    case jar(PersistentIdentifier, month: Date)
    case jarSettings(add: Bool, edit: PersistentIdentifier?)
    case mapping
    case reminders

    @ViewBuilder var view: some View {
        switch self {
        case .jar(let id, let month): JarDetailView(jarID: id, month: month)
        case .jarSettings(let add, let edit): JarSettingsView(startAdding: add, editJar: edit)
        case .mapping: JarMappingView()
        case .reminders: ReminderSettingsView()
        }
    }
}

/// Section title used in each segment ("Jars (6)").
struct BudgetSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.sectionTitle)
            Spacer(minLength: 8)
            trailing.font(.secondaryText).foregroundStyle(Color.brandDeep)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

/// Square action tile under the jar list ("Move between jars", …); wrap in a Button or NavigationLink.
struct ActionTile: View {
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.brandPrimary)
            Text(title).font(.chip).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
        }
        .foregroundStyle(Color.ink)
        .frame(maxWidth: .infinity, minHeight: 92)
        .padding(.horizontal, 4)
        .background(Color.surface.opacity(0.85), in: .rect(cornerRadius: 18))
        .contentShape(.rect)
    }
}

/// Money typed in the major unit ("45000", "12.50"), stored as minor units.
struct AmountField: View {
    let title: String
    @Binding var minor: Int
    var currency = Money.defaultCurrency
    @State private var major: Decimal?

    var body: some View {
        LabeledContent(title) {
            TextField(AmountFormat.string(0, currency), value: $major, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .onChange(of: major) { _, m in minor = Money(major: m ?? 0, currency).minor }
                .onAppear { if minor != 0 { major = Money(minor, currency).major } }
        }
    }
}
