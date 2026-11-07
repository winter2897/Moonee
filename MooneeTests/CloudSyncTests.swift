import Foundation
import SwiftData
import Testing
@testable import Moonee

@MainActor
struct CloudSyncTests {
    /// Builds before the widgets kept the store in Application Support/default.store. The App Group entitlement must not
    /// move it (SwiftData's `.automatic` would open an empty store in the group container): users keep their data.
    @Test func storeStaysWhereEarlierBuildsPutIt() {
        let pinned = ModelConfiguration(schema: Schema.moonee, groupContainer: CloudSync.groupContainer, cloudKitDatabase: .none)
        #expect(pinned.url == URL.applicationSupportDirectory.appending(path: "default.store"))
        let automatic = ModelConfiguration(schema: Schema.moonee, cloudKitDatabase: .none)
        #expect(automatic.url != pinned.url) // the entitlement is there: without the pin the store would move
    }

    /// A reinstall seeds new defaults, then iCloud delivers the old ones (with history): the old copies win,
    /// whatever pointed at the new copies moves over, and user-made jars are kept.
    @Test func mergeDuplicatesKeepsOldestDefaultsAndMovesReferences() throws {
        let container = try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        Seed.ifNeeded(context) // the old install
        let oldFood = try #require(try context.fetch(FetchDescriptor<Moonee.Category>()).first { $0.key == "category.food" })
        let oldNeeds = try #require(oldFood.jar)

        // The new install's seed, made later.
        let later = Date.now.addingTimeInterval(60)
        let newJars = Seed.defaultJars
        newJars.forEach { $0.createdAt = later; context.insert($0) }
        let newFood = Category(key: "category.food", icon: "fork.knife", colorHex: 0, jar: newJars[0])
        newFood.createdAt = later
        context.insert(newFood)
        let mine = Jar(customName: "Trip", icon: "airplane", colorHex: 0, percent: 0, order: 9)
        context.insert(mine)
        let lunch = Txn(amount: 50_000, kind: .expense, category: newFood)
        context.insert(lunch)
        lunch.jar = newJars[0]

        Seed.mergeDuplicates(context)

        let jars = try context.fetch(FetchDescriptor<Jar>())
        #expect(jars.count == 7)
        #expect(jars.contains { $0.customName == "Trip" })
        #expect(try context.fetch(FetchDescriptor<Moonee.Category>()).filter { $0.key == "category.food" }.count == 1)
        #expect(lunch.category?.persistentModelID == oldFood.persistentModelID)
        #expect(lunch.jar?.persistentModelID == oldNeeds.persistentModelID)
    }
}
