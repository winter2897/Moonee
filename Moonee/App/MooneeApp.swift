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

/// The 5 tabs from docs/FEATURES.md §1. Tabs without a screen yet show a placeholder.
struct RootView: View {
    var body: some View {
        TabView {
            Tab("Overview", systemImage: "house.fill") { Placeholder(title: "Overview", spec: "§2") }
            Tab("Budget", systemImage: "square.stack.3d.up.fill") { Placeholder(title: "Budget", spec: "§4") }
            Tab("Moonee", systemImage: "plus.circle.fill") { Placeholder(title: "Moonee", spec: "§3") }
            Tab("Watchlist", systemImage: "chart.line.uptrend.xyaxis") { Placeholder(title: "Watchlist", spec: "§5") }
            Tab("Account", systemImage: "person.fill") { AccountView() }
        }
        .tint(.mooneeGreen)
    }
}

// ponytail: delete once every tab has its real screen
private struct Placeholder: View {
    let title: LocalizedStringKey
    let spec: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: "hammer", description: Text("Not built yet – see docs/FEATURES.md \(spec)"))
                .background(MooneeBackground())
        }
    }
}
