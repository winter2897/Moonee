import SwiftData
import SwiftUI

@main
struct MooneeApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Txn.self, Wallet.self, Category.self, Jar.self)
        } catch {
            fatalError("SwiftData: \(error)")
        }
        Seed.ifNeeded(container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.light) // spec: light mode only
                .task { DevSecrets.load() }
        }
        .modelContainer(container)
    }
}

/// The 5 tabs from docs/FEATURES.md §1. Tabs without a screen yet show a placeholder.
struct RootView: View {
    var body: some View {
        TabView {
            Tab("Tổng quan", systemImage: "house.fill") { Placeholder(title: "Tổng quan", spec: "§2") }
            Tab("Ngân sách", systemImage: "square.stack.3d.up.fill") { Placeholder(title: "Ngân sách", spec: "§4") }
            Tab("Moonee", systemImage: "plus.circle.fill") { Placeholder(title: "Moonee", spec: "§3") }
            Tab("Quan tâm", systemImage: "chart.line.uptrend.xyaxis") { Placeholder(title: "Quan tâm", spec: "§5") }
            Tab("Tài khoản", systemImage: "person.fill") { AccountView() }
        }
        .tint(.mooneeGreen)
    }
}

// ponytail: delete once every tab has its real screen
private struct Placeholder: View {
    let title: String
    let spec: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: "hammer", description: Text("Chưa làm – xem docs/FEATURES.md \(spec)"))
                .background(MooneeBackground())
        }
    }
}
