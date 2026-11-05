import SwiftData
import SwiftUI

@main
struct MooneeApp: App {
    let container: ModelContainer

    init() {
        do {
            // ponytail: local store only. S11 adds the iCloud capability (CloudKit container iCloud.com.haiquan.moonee +
            // remote-notification background mode) with the team; SwiftData then syncs on its own. CloudKitSchemaTests keeps the schema ready.
            container = try ModelContainer(for: Schema.moonee)
        } catch {
            fatalError("SwiftData: \(error)")
        }
        Seed.ifNeeded(container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            RootView() // light only: UIUserInterfaceStyle = Light in build settings
                .task { DevSecrets.load() }
        }
        .modelContainer(container)
    }
}

enum AppTab: Hashable { case overview, budget, moonee, watchlist, account }

/// The 5 tabs from docs/FEATURES.md §1 with the mockups' floating bar; (+) opens the Moonee chat.
/// Each tab's root view lives in its feature folder, so feature sessions never need to edit this file.
struct RootView: View {
    @State private var tab = AppTab.overview
    /// Where the chat's back button returns to.
    @State private var lastTab = AppTab.overview
    @AppStorage(Prefs.hideBalances) private var hideBalances = false

    var body: some View {
        TabView(selection: $tab) {
            Tab(value: .overview) { OverviewView() }
            Tab(value: .budget) { BudgetView() }
            Tab(value: .moonee) { ChatView { tab = lastTab } }
            Tab(value: .watchlist) { WatchlistView() }
            Tab(value: .account) { AccountView() }
        }
        .toolbar(.hidden, for: .tabBar)
        .onChange(of: tab) { old, _ in if old != .moonee { lastTab = old } }
        .safeAreaInset(edge: .bottom) {
            // The chat is full screen with its own input bar (mockup); the bar comes back on Back.
            if tab != .moonee {
                MooneeTabBar(items: [
                    .init(tab: .overview, title: String(localized: "Overview"), symbol: "house"),
                    .init(tab: .budget, title: String(localized: "Budget"), symbol: "wallet.bifold"),
                    .init(tab: .watchlist, title: String(localized: "Watchlist"), symbol: "chart.bar"),
                    .init(tab: .account, title: String(localized: "Account"), symbol: "person"),
                ], selection: $tab) { tab = .moonee }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .environment(\.balanceHidden, hideBalances)
        .tint(.mooneeGreen)
    }
}

/// UserDefaults keys shared across features (plain settings; secrets go in Keychain).
enum Prefs {
    /// Bool. Hide every amount (spec §6.4); `AmountText` reads it via `\.balanceHidden`.
    static let hideBalances = "privacy.hideBalances"
    /// String. Display name from profile setup (spec §7 step 0), on device only.
    static let profileName = "profile.name"
    /// String. Asset name of the chosen avatar (`avatar.*`).
    static let profileAvatar = "profile.avatar"
    /// String: "low" | "medium" | "high". Reminder level (spec §3.4), default medium.
    static let reminderLevel = "reminders.level"
}

// ponytail: delete once every tab has its real screen
struct Placeholder: View {
    let title: LocalizedStringKey
    let spec: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: "hammer", description: Text("Not built yet – see docs/FEATURES.md \(spec)"))
                .background(MooneeBackground())
        }
    }
}
