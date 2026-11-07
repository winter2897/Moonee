import Combine
import CoreData
import SwiftData
import SwiftUI
import WidgetKit

extension WidgetSnapshot {
    /// The widgets' numbers now, from the same `BudgetFacts` as the Budget tab; today's spend as on Overview.
    @MainActor init(_ context: ModelContext, now: Date = .now, calendar: Calendar = .current,
                    hidden: Bool = UserDefaults.standard.bool(forKey: Prefs.hideBalances)) {
        let facts = BudgetFacts(context, now: now, calendar: calendar)
        let colors = Dictionary(((try? context.fetch(FetchDescriptor<Moonee.Jar>())) ?? []).map { ($0.parserKey, $0.colorHex) },
                                uniquingKeysWith: { a, _ in a })
        let day = calendar.dateInterval(of: .day, for: now)!
        let (start, end, expense) = (day.start, day.end, TxKind.expense.rawValue)
        let today = (try? context.fetch(FetchDescriptor<Txn>(predicate: #Predicate { $0.date >= start && $0.date < end && $0.kindRaw == expense }))) ?? []
        self.init(date: now, currency: Money.defaultCurrency, hidden: hidden, spentToday: today.reduce(0) { $0 + $1.amount },
                  jars: facts.jars.map { Jar(name: $0.name, colorHex: colors[$0.key] ?? 0x64748B, budget: $0.budget, spent: $0.spent, balance: $0.balance) })
    }
}

/// Keeps the widget file in the App Group current and asks WidgetKit to redraw when it changed.
@MainActor enum WidgetSync {
    static func refresh(_ context: ModelContext, to url: URL? = WidgetSnapshot.url, now: Date = .now) {
        guard let url else { return }
        let new = WidgetSnapshot(context, now: now)
        if var old = WidgetSnapshot.load(from: url), Calendar.current.isDate(old.date, inSameDayAs: now) {
            old.date = now
            if old == new { return } // same numbers: no write, no reload
        }
        guard let data = try? JSONEncoder().encode(new), (try? data.write(to: url, options: .atomic)) != nil else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension View {
    /// Refreshes the widgets after every save (chat, forms, import, Autopilot), iCloud imports, a settings change
    /// (hide balances, currency) and when the app leaves the foreground. Attached once in `RootView`.
    func widgetSync() -> some View { modifier(WidgetSyncModifier()) }
}

private struct WidgetSyncModifier: ViewModifier {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        let center = NotificationCenter.default
        content
            .onReceive(center.publisher(for: ModelContext.didSave)
                .merge(with: center.publisher(for: .NSPersistentStoreRemoteChange), center.publisher(for: UserDefaults.didChangeNotification))
                .debounce(for: .seconds(1), scheduler: RunLoop.main)) { _ in WidgetSync.refresh(context) }
            .onChange(of: phase) { _, p in if p == .background { WidgetSync.refresh(context) } }
            .task { WidgetSync.refresh(context) }
    }
}
