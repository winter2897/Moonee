import CloudKit
import CoreData
import SwiftData

/// iCloud sync (spec §6.3): SwiftData mirrors the store to the user's private CloudKit database.
/// No account, iCloud off for Moonee, or no network: the same local store keeps working and syncs when iCloud is back.
@MainActor enum CloudSync {
    static let containerID = "iCloud.com.haiquan.moonee"
    /// The store was opened with CloudKit mirroring. False = local-only fallback (CloudKit could not start).
    private(set) static var isOn = false

    /// `Prefs.iCloudSync` when the store opened: the Account toggle takes effect on the next launch.
    private(set) static var requested = true

    /// The store stays in the app's own Application Support (`default.store`), where every build so far put it.
    /// With the App Group entitlement (widgets) SwiftData's `.automatic` would open a new, empty store in the group
    /// container instead, so it is pinned. The widgets never open the store: they read `WidgetSnapshot`.
    static let groupContainer = ModelConfiguration.GroupContainer.none

    static func makeContainer() throws -> ModelContainer {
        requested = UserDefaults.standard.object(forKey: Prefs.iCloudSync) as? Bool ?? true
        if requested {
            do {
                let container = try ModelContainer(for: Schema.moonee,
                                                   configurations: ModelConfiguration(schema: Schema.moonee, groupContainer: groupContainer,
                                                                                      cloudKitDatabase: .private(containerID)))
                isOn = true
                return container
            } catch {
                print("iCloud sync off, local store only: \(error)")
            }
        }
        return try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(schema: Schema.moonee, groupContainer: groupContainer,
                                                                                         cloudKitDatabase: .none))
    }

    enum Status { case on, noAccount, unavailable, off }

    static func status() async -> Status {
        guard isOn else { return .off }
        switch try? await CKContainer(identifier: containerID).accountStatus() {
        case .available: return .on
        case .noAccount: return .noAccount
        default: return .unavailable // restricted, temporarily unavailable, or unknown
        }
    }
}

extension Seed {
    /// A fresh install seeds the default jars/categories before iCloud delivers the ones from an earlier install,
    /// so each key ends up twice. Keep the oldest copy (every device picks the same one, so they converge),
    /// move everything that pointed at the others onto it, delete the rest. User-made jars/categories (no key) are left alone.
    @MainActor static func mergeDuplicates(_ context: ModelContext) {
        let jars = (try? context.fetch(FetchDescriptor<Jar>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        var keptJars: [String: Jar] = [:]
        for jar in jars {
            guard let key = jar.key else { continue }
            guard let keep = keptJars[key] else { keptJars[key] = jar; continue }
            (jar.categories ?? []).forEach { $0.jar = keep }
            (jar.txns ?? []).forEach { $0.jar = keep }
            (jar.incoming ?? []).forEach { $0.toJar = keep }
            (jar.splits ?? []).forEach { $0.jar = keep }
            (jar.goals ?? []).forEach { $0.jar = keep }
            context.delete(jar)
        }

        let categories = (try? context.fetch(FetchDescriptor<Category>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        var keptCategories: [String: Category] = [:]
        for category in categories {
            guard let key = category.key else { continue }
            guard let keep = keptCategories[key] else { keptCategories[key] = category; continue }
            if keep.jar == nil, category.kind == .expense { keep.jar = category.jar } // an old "Other" meets the new seed's jar (P0-2)
            (category.txns ?? []).forEach { $0.category = keep }
            (category.recurrings ?? []).forEach { $0.category = keep }
            (category.rules ?? []).forEach { $0.category = keep }
            context.delete(category)
        }
        if context.hasChanges { try? context.save() }
    }
}
