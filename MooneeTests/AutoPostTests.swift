import Foundation
import SwiftData
import Testing
@testable import Moonee

/// P1-4: bills that record themselves on the due day (`Recurring.autoPost`, `Autopilot.postBills`).
@MainActor final class AutoPostTests {
    /// Every bill here is named "Test bill …": the test host shares the simulator app's UserDefaults, so drop what we left.
    nonisolated static let name = "Test bill "

    deinit {
        let mine = { (tag: String) in tag.hasPrefix(Autopilot.billPrefix + Self.name) }
        AdvisorMemory.setAutoRecords(AdvisorMemory.autoRecords.filter { !mine($0.tag) })
        let d = UserDefaults.standard
        d.set((d.stringArray(forKey: Prefs.autoPostUndone) ?? []).filter { !mine($0) }, forKey: Prefs.autoPostUndone)
    }

    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    func at(_ m: Int, _ d: Int, _ h: Int = 12) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))! }

    func seeded() throws -> ModelContext {
        let context = ModelContext(try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        Seed.ifNeeded(context)
        return context
    }

    /// A fixed bill set to record itself. A unique name: the undone set lives in UserDefaults, shared by parallel tests.
    func bill(_ due: Date, frequency: Frequency = .monthly, estimate: Bool = false, _ context: ModelContext) -> Recurring {
        let r = Recurring(name: Self.name + UUID().uuidString.prefix(6), amount: 260_000, currencyCode: "VND", frequency: frequency, nextDue: due)
        r.autoPost = true
        r.isEstimate = estimate
        context.insert(r)
        r.category = (try? context.fetch(FetchDescriptor<Moonee.Category>()))?.first { $0.key == "category.entertainment" }
        return r
    }

    func posted(_ r: Recurring, _ context: ModelContext) throws -> [Txn] {
        let prefix = Autopilot.billPrefix + r.name + ":"
        return try context.fetch(FetchDescriptor<Txn>(sortBy: [SortDescriptor(\.date)])).filter { $0.externalID?.hasPrefix(prefix) == true }
    }

    @Test func postsOnceOnTheDueDayIncludingToday() throws {
        let context = try seeded()
        let morning = bill(at(11, 7, 8), context)
        let tonight = bill(at(11, 7, 21), context) // set for today in the form: today counts, not "from next period"
        let tomorrow = bill(at(11, 8, 8), context)
        Autopilot.postBills(context, now: at(11, 7, 10), calendar: cal)
        Autopilot.postBills(context, now: at(11, 7, 11), calendar: cal) // the next app open the same day
        let t = try #require(try posted(morning, context).first)
        #expect(try posted(morning, context).count == 1)
        #expect(t.kind == .expense && t.amount == 260_000 && t.jar != nil)
        #expect(t.externalID == Autopilot.postTag(morning.name, due: at(11, 7), calendar: cal))
        #expect(cal.isDate(morning.nextDue, inSameDayAs: at(12, 7)))
        #expect(try posted(tonight, context).count == 1)
        #expect(try #require(try posted(tonight, context).first).date <= at(11, 7, 10)) // not dated in the future
        #expect(try posted(tomorrow, context).isEmpty)
        // Said in today's chat, with the txn on its card.
        let thread = try #require(ChatThreads.todays(now: at(11, 7, 10), calendar: cal, in: context))
        #expect(thread.sortedMessages.count == 2)
        #expect(thread.sortedMessages.contains { $0.savedTxns.first == t })
    }

    @Test func catchesUpMissedPeriodsOnceEach() throws {
        let context = try seeded()
        let r = bill(at(8, 15, 9), context)
        Autopilot.postBills(context, now: at(11, 7), calendar: cal)
        Autopilot.postBills(context, now: at(11, 7), calendar: cal)
        #expect(try posted(r, context).map { cal.component(.month, from: $0.date) } == [8, 9, 10])
        #expect(cal.isDate(r.nextDue, inSameDayAs: at(11, 15)))
    }

    @Test func estimatesAndManualBillsWait() throws {
        let context = try seeded()
        let estimate = bill(at(11, 1), estimate: true, context)
        let manual = bill(at(11, 1), context)
        manual.autoPost = false
        Autopilot.postBills(context, now: at(11, 7), calendar: cal)
        #expect(try posted(estimate, context).isEmpty && posted(manual, context).isEmpty)
        #expect(cal.isDate(estimate.nextDue, inSameDayAs: at(11, 1)))
    }

    @Test func undoPutsTheBillBackToDueAndNeverRepostsIt() throws {
        let context = try seeded()
        let r = bill(at(11, 7, 8), context)
        let record = try #require(Autopilot.postBills(context, now: at(11, 7, 10), calendar: cal).first)
        let message = try #require(try posted(r, context).first?.chatMessage)
        Autopilot.undo(record, in: context) // the Budget card's Undo
        #expect(try posted(r, context).isEmpty)
        #expect(message.undone) // the chat card is struck through
        #expect(cal.isDate(r.nextDue, inSameDayAs: at(11, 7))) // due again: Coming up shows it with Mark paid
        Autopilot.postBills(context, now: at(11, 7, 18), calendar: cal)
        #expect(try posted(r, context).isEmpty)
    }

    @Test func chatUndoAlsoPutsTheBillBack() throws {
        let context = try seeded()
        let r = bill(at(11, 7, 8), context)
        Autopilot.postBills(context, now: at(11, 7, 10), calendar: cal)
        let message = try #require(try posted(r, context).first?.chatMessage)
        ChatBook.undo(message, in: context)
        #expect(try posted(r, context).isEmpty)
        #expect(cal.isDate(r.nextDue, inSameDayAs: at(11, 7)))
        #expect(!AdvisorMemory.autoRecords.contains { $0.tag.hasPrefix(Autopilot.billPrefix + r.name) })
    }

    @Test func anotherDevicesPostIsNotRepeated() throws {
        let context = try seeded()
        let r = bill(at(11, 7, 8), context)
        let theirs = Txn(amount: 260_000, kind: .expense, currencyCode: "VND", date: at(11, 7, 8), note: r.name)
        theirs.externalID = Autopilot.postTag(r.name, due: at(11, 7), calendar: cal) // synced from the other iPhone
        context.insert(theirs)
        Autopilot.postBills(context, now: at(11, 7, 10), calendar: cal)
        #expect(try posted(r, context) == [theirs])
        #expect(cal.isDate(r.nextDue, inSameDayAs: at(12, 7)))
    }

    @Test func iCloudImportDuplicatesAreDropped() throws {
        let context = try seeded()
        let tag = Autopilot.postTag("Rent", due: at(11, 1), calendar: cal)
        let mine = Txn(amount: 5_000_000, kind: .expense, date: at(11, 1))
        mine.createdAt = at(11, 1, 9)
        let theirs = Txn(amount: 5_000_000, kind: .expense, date: at(11, 1))
        theirs.createdAt = at(11, 1, 10)
        for t in [mine, theirs] { t.externalID = tag; context.insert(t) }
        Autopilot.dropDuplicatePosts(context)
        let tagged: String? = tag
        #expect(try context.fetch(FetchDescriptor<Txn>(predicate: #Predicate { $0.externalID == tagged })) == [mine])
    }

    @Test func reminderSaysRecordedInsteadOfDue() {
        let plan = ReminderPlanner.plan(bills: [.init(name: "Netflix", due: at(11, 10), remindDaysBefore: 3, autoPost: true)],
                                        settings: .init(level: .low), now: at(11, 5), calendar: cal)
        #expect(plan.map(\.kind) == [.autoPosted])
        #expect(plan.map(\.date) == [at(11, 10, 9)])
        #expect(Reminders.text(plan[0]).1.contains("Netflix"))
    }
}
