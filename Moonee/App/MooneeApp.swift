import Combine
import CoreData
import SwiftData
import SwiftUI

@main
struct MooneeApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try CloudSync.makeContainer() // iCloud (private DB) or the local fallback
        } catch {
            fatalError("SwiftData: \(error)")
        }
        Seed.ifNeeded(container.mainContext)
        Seed.mergeDuplicates(container.mainContext)
        LLMSettings.migrate() // one-time: old openAICompatible provider → OpenRouter / Custom
    }

    var body: some Scene {
        WindowGroup {
            RootView() // light only: UIUserInterfaceStyle = Light in build settings
                .task { DevSecrets.load() }
                // iCloud just delivered records (e.g. a reinstall meeting its old data): fold duplicate defaults.
                .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
                    .debounce(for: .seconds(2), scheduler: RunLoop.main)) { _ in Seed.mergeDuplicates(container.mainContext) }
        }
        .modelContainer(container)
    }
}

enum AppTab: Hashable { case overview, budget, moonee, watchlist, account }

/// The 5 tabs from docs/FEATURES.md §1 on the system tab bar (iOS 26 Liquid Glass selection: press, drag, settle).
/// Moonee sits in the centre as in the mockups and opens the full-screen chat, which hides the bar; its Back returns to the last tab.
/// Each tab's root view lives in its feature folder, so feature sessions never need to edit this file.
struct RootView: View {
    @State private var tab = AppTab.overview
    /// Where the chat's back button returns to.
    @State private var lastTab = AppTab.overview
    @AppStorage(Prefs.hideBalances) private var hideBalances = false

    private static let plusIcon = UIImage(systemName: "plus.circle.fill", withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))!
        .withTintColor(UIColor(Color.brandPrimary), renderingMode: .alwaysOriginal)

    var body: some View {
        TabView(selection: $tab) {
            Tab(String(localized: "Overview"), systemImage: "house", value: .overview) { OverviewView().statusBarScrim() }
            Tab(String(localized: "Budget"), systemImage: "wallet.bifold", value: .budget) { BudgetView().statusBarScrim() }
            Tab(value: .moonee) {
                // Full screen with its own composer (mockup): no tab bar inside the chat.
                ChatView { tab = lastTab }.toolbarVisibility(.hidden, for: .tabBar)
            } label: {
                // Green (+) like the mockup's centre button; `.alwaysOriginal` keeps the tab bar from tinting it.
                Label { Text(verbatim: "Moonee") } icon: { Image(uiImage: Self.plusIcon) }
            }
            Tab(String(localized: "Watchlist"), systemImage: "chart.bar", value: .watchlist) { WatchlistView().statusBarScrim() }
            Tab(String(localized: "Account"), systemImage: "person", value: .account) { AccountView().statusBarScrim() }
        }
        .onChange(of: tab) { old, _ in if old != .moonee { lastTab = old } }
        .environment(\.balanceHidden, hideBalances)
        .reminderScheduling()
        .tint(.brandDeep)
        .onboarding() // first launch only (Features/Onboarding)
        .appLock() // Face ID lock + App Switcher cover (Features/Account/Security.swift)
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
