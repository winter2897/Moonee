import SwiftData
import SwiftUI

@main
struct MooneeApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Txn.self, Wallet.self, Category.self, Jar.self, MonthlyReport.self)
        } catch {
            fatalError("SwiftData: \(error)")
        }
        Seed.ifNeeded(container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.light) // ponytail: light-only like the mockups, add dark palette later
                .task { await Accountant.runDaily(container) }
        }
        .modelContainer(container)
        .backgroundTask(.appRefresh(Accountant.refreshTaskID)) { await Accountant.runDaily(container) }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Nhập", systemImage: "plus.circle.fill") { EntryView() }
            Tab("Chi tiêu", systemImage: "chart.bar.fill") { SpendingView() }
            Tab("Ví", systemImage: "wallet.bifold.fill") { WalletsView() }
            Tab("Tài khoản", systemImage: "person.fill") { AccountView() }
        }
        .tint(.mooneeGreen)
    }
}
