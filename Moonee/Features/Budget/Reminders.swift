import Foundation
import SwiftData
import SwiftUI
import UserNotifications

/// Spec §3.4 reminder level, stored in `Prefs.reminderLevel`.
enum ReminderLevel: String, CaseIterable, Identifiable, Comparable {
    case low, medium, high
    var id: String { rawValue }

    static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }

    /// Spam guard (spec §3.4): most notifications per day.
    var dailyCap: Int {
        switch self {
        case .low: 2
        case .medium: 3
        case .high: 5
        }
    }

    var title: String {
        switch self {
        case .low: loc("Low")
        case .medium: loc("Medium")
        case .high: loc("High")
        }
    }

    var summary: String {
        switch self {
        case .low: loc("Bills due and jars over 100%.")
        case .medium: loc("Plus jars at 80%, weekly and monthly reports, debts to collect or repay.")
        case .high: loc("Plus an evening nudge to log the day's spending.")
        }
    }

    static var current: ReminderLevel {
        UserDefaults.standard.string(forKey: Prefs.reminderLevel).flatMap(ReminderLevel.init) ?? .medium
    }
}

extension Prefs {
    /// Int, minutes after midnight. Quiet hours: nothing is delivered between start and end (default 22:00–07:00).
    static let quietStart = "reminders.quietStart"
    static let quietEnd = "reminders.quietEnd"
    /// [String]. Jar alerts already sent ("jar.over.<jar>.<yyyy-MM>"), so each fires once a month.
    static let remindersSent = "reminders.sent"
    /// Bool. Moonee asked iOS for full alerts once (after onboarding); later it is the Reminders screen's button.
    static let remindersAsked = "reminders.asked"
}

/// One notification to schedule. Same-kind alerts on the same day are grouped into one (`items`).
struct Reminder: Equatable {
    /// Raw order = priority when the daily cap drops some.
    enum Kind: Int, CaseIterable, Comparable {
        case jarOver, limitOver, payday, bill, jarWarning, limitWarning, debt, monthlyReport, weeklyReport, debtNudge, dailyLog

        var minLevel: ReminderLevel {
            switch self {
            case .jarOver, .limitOver, .payday, .bill: .low
            case .jarWarning, .limitWarning, .debt, .monthlyReport, .weeklyReport, .debtNudge: .medium
            case .dailyLog: .high
            }
        }

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    var kind: Kind
    var date: Date
    /// Names shown in the body (bills, jars, people). Empty for reports.
    var items: [String] = []
    /// Once-only keys (jar alerts) to remember after scheduling.
    var keys: [String] = []
    /// Moonee's advice as the body (payday plan, how to fix a jar), instead of the kind's template.
    var title: String?
    var body: String?
}

/// Pure planning: what to notify and when. No UserNotifications, so it is unit-tested.
enum ReminderPlanner {
    struct Bill { var name: String; var due: Date; var remindDaysBefore: Int }
    struct JarState { var id: String; var name: String; var level: BudgetLevel; var advice: String? = nil }
    /// An open debt. With a due date: that morning (and the day before when the user owes it). Without one, or past it:
    /// a gentle nudge every two weeks from `since` (the last lend/borrow/repay). `amount` is what is left, formatted.
    struct DebtDue {
        var person: String
        var due: Date?
        var amount = ""
        var owedByMe = false
        var since: Date?
    }
    static let debtNudgeDays = 14
    /// "Salary 40tr in yet?" on payday morning with Moonee's split (spec §4.6 moment 2).
    struct Payday { var name: String; var due: Date; var title: String; var body: String }

    struct Settings {
        var level: ReminderLevel = .medium
        /// Minutes after midnight. start == end turns quiet hours off.
        var quietStart = 22 * 60
        var quietEnd = 7 * 60
        var morning = 9 * 60
        var evening = 20 * 60 + 30
        var weeklyReport = 19 * 60
        /// Days planned ahead, today included (iOS keeps at most 64 pending notifications).
        var horizonDays = 14
    }

    /// `limits`: categories with a monthly limit (spec P1-1), alerted at 80% and 100% like jars.
    static func plan(bills: [Bill] = [], jars: [JarState] = [], limits: [JarState] = [], debts: [DebtDue] = [], paydays: [Payday] = [], settings: Settings = .init(),
                     now: Date, sent: Set<String> = [], deliveredToday: Int = 0, calendar: Calendar = .current) -> [Reminder] {
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: settings.horizonDays, to: today)!
        func at(_ day: Date, _ minutes: Int) -> Date { calendar.date(byAdding: .minute, value: minutes, to: calendar.startOfDay(for: day))! }

        var raw: [Reminder] = []
        // Bills: N days before and on the due day.
        for b in bills {
            let due = calendar.startOfDay(for: b.due)
            let days = Set([max(b.remindDaysBefore, 0), 0]).compactMap { calendar.date(byAdding: .day, value: -$0, to: due) }
            raw += days.map { Reminder(kind: .bill, date: at($0, settings.morning), items: [b.name]) }
        }
        // Jars: once per month per jar and level, as soon as possible.
        let month = calendar.dateComponents([.year, .month], from: now)
        let monthTag = String(format: "%04d-%02d", month.year ?? 0, month.month ?? 0)
        for (j, isLimit) in jars.map({ ($0, false) }) + limits.map({ ($0, true) }) {
            let over: Bool
            switch j.level {
            case .over, .negative: over = true
            case .warning: over = false
            case .normal: continue
            }
            let kind: Reminder.Kind = isLimit ? (over ? .limitOver : .limitWarning) : (over ? .jarOver : .jarWarning)
            let prefix = isLimit ? "limit" : "jar"
            let key = "\(prefix).\(over ? "over" : "warn").\(j.id).\(monthTag)"
            // An over alert also covers the 80% one.
            if sent.contains(key) || (!over && sent.contains("\(prefix).over.\(j.id).\(monthTag)")) { continue }
            raw.append(Reminder(kind: kind, date: now, items: [j.name], keys: [key], body: kind == .jarOver ? j.advice : nil))
        }
        for p in paydays { raw.append(Reminder(kind: .payday, date: at(p.due, settings.morning), items: [p.name], title: p.title, body: p.body)) }
        for d in debts {
            let (person, amount) = (d.person, d.amount)
            if let due = d.due.map(calendar.startOfDay), due >= today {
                raw.append(Reminder(kind: .debt, date: at(due, settings.morning), items: [person], body: d.owedByMe
                    ? String(localized: "Today you're due to pay \(person) back \(amount).", table: "Budget")
                    : String(localized: "\(person) is due to pay you back \(amount) today. A gentle nudge?", table: "Budget")))
                if d.owedByMe, let before = calendar.date(byAdding: .day, value: -1, to: due) {
                    raw.append(Reminder(kind: .debt, date: at(before, settings.morning), items: [person],
                                        body: String(localized: "Tomorrow you're due to pay \(person) back \(amount).", table: "Budget")))
                }
            } else {
                var next = calendar.startOfDay(for: d.due ?? d.since ?? now)
                repeat { next = calendar.date(byAdding: .day, value: debtNudgeDays, to: next)! } while next < today
                raw.append(Reminder(kind: .debtNudge, date: at(next, settings.morning), items: [person], body: d.owedByMe
                    ? String(localized: "You still owe \(person) \(amount). Pay it back when you can?", table: "Budget")
                    : String(localized: "\(person) still owes you \(amount). A gentle reminder?", table: "Budget")))
            }
        }
        // Reports and the evening nudge, every day in the horizon.
        var day = today
        while day < end {
            if calendar.component(.weekday, from: day) == 1 { raw.append(Reminder(kind: .weeklyReport, date: at(day, settings.weeklyReport))) }
            if calendar.component(.day, from: day) == 1 { raw.append(Reminder(kind: .monthlyReport, date: at(day, settings.morning))) }
            raw.append(Reminder(kind: .dailyLog, date: at(day, settings.evening)))
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }

        // Level filter, quiet hours, horizon. Immediate alerts (jars) may be "now".
        let shifted = raw
            .filter { $0.kind.minLevel <= settings.level }
            .map { r in var r = r; r.date = outOfQuietHours(r.date, settings, calendar); return r }
            .filter { $0.date >= now && $0.date < end }

        // Group same kind + same day.
        var groups: [String: Reminder] = [:]
        for r in shifted {
            let k = "\(r.kind.rawValue)|\(calendar.startOfDay(for: r.date).timeIntervalSince1970)"
            if var g = groups[k] {
                g.date = min(g.date, r.date)
                g.items += r.items.filter { !g.items.contains($0) }
                g.keys += r.keys
                if g.items.count > 1 { g.body = nil } // grouped: the plain template names them all
                groups[k] = g
            } else {
                groups[k] = r
            }
        }

        // Daily cap, highest priority first.
        let byDay = Dictionary(grouping: groups.values) { calendar.startOfDay(for: $0.date) }
        return byDay.flatMap { day, list in
            let cap = settings.level.dailyCap - (day == today ? deliveredToday : 0)
            return list.sorted { ($0.kind, $0.date) < ($1.kind, $1.date) }.prefix(max(cap, 0))
        }
        .sorted { ($0.date, $0.kind) < ($1.date, $1.kind) }
        .prefix(maxPending).map { $0 }
    }

    /// iOS keeps at most 64 pending local notifications per app and silently drops the rest.
    static let maxPending = 60

    /// Moves a date out of quiet hours to the moment they end.
    static func outOfQuietHours(_ date: Date, _ s: Settings, _ calendar: Calendar) -> Date {
        guard s.quietStart != s.quietEnd else { return date }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let quiet = s.quietStart < s.quietEnd ? (m >= s.quietStart && m < s.quietEnd) : (m >= s.quietStart || m < s.quietEnd)
        guard quiet else { return date }
        var day = calendar.startOfDay(for: date)
        if s.quietStart > s.quietEnd, m >= s.quietStart { day = calendar.date(byAdding: .day, value: 1, to: day)! }
        return calendar.date(byAdding: .minute, value: s.quietEnd, to: day)!
    }
}

/// Builds the planner's input from SwiftData and replaces Moonee's pending local notifications.
@MainActor enum Reminders {
    static let prefix = "moonee."
    /// Jar alerts are once-only: kept across refreshes instead of re-planned.
    static let jarPrefix = "moonee.jar."

    static func refresh(_ context: ModelContext, now: Date = .now) async {
        let center = UNUserNotificationCenter.current()
        center.delegate = ReminderPresenter.shared
        let defaults = UserDefaults.standard
        var status = await center.notificationSettings().authorizationStatus
        // Real alerts, asked once after onboarding (which has its own toggle). Provisional permission used to be asked
        // silently at first launch: iOS then delivers quietly to Notification Center only (no banner, sound or lock screen),
        // so a user who skipped the onboarding toggle never saw a reminder. Asking again from provisional shows the prompt.
        if status == .notDetermined || status == .provisional, defaults.bool(forKey: Prefs.onboardingDone), !defaults.bool(forKey: Prefs.remindersAsked) {
            defaults.set(true, forKey: Prefs.remindersAsked)
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }

        var settings = ReminderPlanner.Settings(level: ReminderLevel.current)
        if defaults.object(forKey: Prefs.quietStart) != nil {
            settings.quietStart = defaults.integer(forKey: Prefs.quietStart)
            settings.quietEnd = defaults.integer(forKey: Prefs.quietEnd)
        }
        let cal = Calendar.current
        let txns = (try? context.fetch(FetchDescriptor<Txn>())) ?? []
        let wallets = (try? context.fetch(FetchDescriptor<Wallet>())) ?? []
        let jars = (try? context.fetch(FetchDescriptor<Jar>())) ?? []
        let ledger = Ledger(txns: txns, wallets: wallets, jars: jars)
        let month = cal.dateInterval(of: .month, for: now)!

        var bills = ((try? context.fetch(FetchDescriptor<Recurring>())) ?? []).filter { !$0.isIncome }
            .map { ReminderPlanner.Bill(name: $0.name, due: $0.nextDue, remindDaysBefore: $0.remindDaysBefore) }
        for card in wallets where card.type == .credit {
            if let day = card.dueDay, ledger.walletBalance(card.persistentModelID) < 0 {
                bills.append(.init(name: card.name, due: BudgetActions.nextDate(day: day, from: now, calendar: cal), remindDaysBefore: 3))
            }
        }
        let jarStates = jars.map { j in
            let m = ledger.jarMonth(j.persistentModelID, in: month)
            return ReminderPlanner.JarState(id: j.key ?? j.name, name: j.name, level: BudgetLevel(balance: m.endBalance, spent: m.spent, budget: m.budget))
        }
        let debts = ((try? context.fetch(FetchDescriptor<Debt>())) ?? []).compactMap { d -> ReminderPlanner.DebtDue? in
            guard let left = ledger.debtRemaining[d.persistentModelID], left > 0 else { return nil }
            return .init(person: d.person, due: d.dueDate, amount: Money(left, d.currencyCode).formatted(), owedByMe: d.direction == .borrowed,
                         since: (d.txns ?? []).map(\.date).max() ?? d.createdAt)
        }

        // Moonee's advice (spec §4.6): how to fix a jar, and the payday plan.
        let facts = BudgetFacts(context, now: now, calendar: cal)
        let fix = facts.advice.first { $0.kind == .noMoney || $0.kind == .negativeJar }
        let advisedJars = jarStates.map { j in var j = j; j.advice = fix.map { "\($0.title). \($0.text)" }; return j }
        let level = AdvisorLevel.current
        let paydays = ((try? context.fetch(FetchDescriptor<Recurring>())) ?? [])
            .filter { $0.isIncome && !BudgetActions.isReceived($0, txns: txns, calendar: cal) }
            .map { r -> ReminderPlanner.Payday in
                let title = String(localized: "\(r.name) \(AmountFormat.string(r.amount, r.currencyCode, short: true)) in yet?", table: "Budget")
                let plan = BudgetFacts(context, now: r.nextDue, calendar: cal).advice.first { $0.kind == .payday }?.text
                let body = switch level {
                case .automatic: loc("Payday! Open Moonee and it records your salary and splits it by its plan.")
                case .suggest: plan.map { "\($0) " + loc("Tap Received in Budget once it's in.") } ?? loc("Tap Received in Budget once it's in.")
                case .manual: loc("Tap Received in Budget once it's in.")
                }
                return .init(name: r.name, due: r.nextDue, title: title, body: body)
            }

        var sent = Set(defaults.stringArray(forKey: Prefs.remindersSent) ?? [])
        let delivered = await center.deliveredNotifications()
            .filter { $0.request.identifier.hasPrefix(prefix) && cal.isDate($0.date, inSameDayAs: now) }.count
        let limits = facts.limited.map { ReminderPlanner.JarState(id: $0.key, name: $0.name, level: $0.level ?? .normal) }
        let plan = ReminderPlanner.plan(bills: bills, jars: advisedJars, limits: limits, debts: debts, paydays: paydays, settings: settings, now: now,
                                        sent: sent, deliveredToday: delivered, calendar: cal)

        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) && !$0.hasPrefix(jarPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        for r in plan {
            let content = UNMutableNotificationContent()
            (content.title, content.body) = text(r)
            if let title = r.title { content.title = title }
            if let body = r.body { content.body = body }
            content.sound = .default
            content.threadIdentifier = "\(prefix)\(r.kind)"
            let trigger: UNNotificationTrigger = r.date.timeIntervalSince(now) < 60
                ? UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
                : UNCalendarNotificationTrigger(dateMatching: cal.dateComponents([.year, .month, .day, .hour, .minute], from: r.date), repeats: false)
            let day = Int(cal.startOfDay(for: r.date).timeIntervalSince1970)
            let id = r.keys.isEmpty ? "\(prefix)\(r.kind).\(day)" : "\(jarPrefix)\(r.keys.joined(separator: ","))"
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            sent.formUnion(r.keys)
        }
        // ponytail: keys pile up a dozen a month; prune old months if this ever matters.
        defaults.set(Array(sent), forKey: Prefs.remindersSent)
    }

    static func text(_ r: Reminder) -> (String, String) {
        let names = r.items.formatted(.list(type: .and))
        return switch r.kind {
        case .payday: (loc("Payday"), String(localized: "\(names): tap Received in Budget once it's in.", table: "Budget"))
        case .jarOver: (loc("A jar went over"), String(localized: "\(names) went past this month's budget. Moonee can help you move money from another jar.", table: "Budget"))
        case .jarWarning: (loc("Heads up: 80% used"), String(localized: "\(names) has used 80% of this month's budget. Go easy for a bit!", table: "Budget"))
        case .limitOver: (loc("Over a spending limit"), String(localized: "\(names) went past this month's limit. The jar still pays, but take it easy.", table: "Budget"))
        case .limitWarning: (loc("80% of a limit"), String(localized: "\(names) has used 80% of this month's limit.", table: "Budget"))
        case .bill: (loc("Bill reminder"), String(localized: "\(names) is due soon. Tap Mark paid in Budget once it's done.", table: "Budget"))
        case .debt: (loc("Debt due"), String(localized: "Debts due soon with \(names). Open the debt book in Budget.", table: "Budget"))
        case .debtNudge: (loc("Debt book"), String(localized: "Still open in your debt book: \(names).", table: "Budget"))
        case .weeklyReport: (loc("Your week with Moonee"), loc("Your weekly report is ready. Take a quick look?"))
        case .monthlyReport: (loc("New month, fresh jars"), loc("Last month's report is ready. See how your jars did!"))
        case .dailyLog: (loc("Anything to log today?"), loc("Tell Moonee what you spent today, it takes a few seconds."))
        }
    }
}

/// iOS shows nothing for a notification that fires while the app is open unless a delegate asks for it:
/// a jar alert (5 s after the save that caused it) was lost, and marked sent.
final class ReminderPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ReminderPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    #if DEBUG
    /// Reminder settings' debug row: one notification in 5 s, through the same path as the real ones.
    @MainActor static func sendTest() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        let content = UNMutableNotificationContent()
        (content.title, content.body) = Reminders.text(Reminder(kind: .debtNudge, date: .now, items: ["Nam"]))
        content.sound = .default
        // Not "moonee.…": a refresh in the next 5 s would remove it.
        try? await center.add(UNNotificationRequest(identifier: "debug.test", content: content,
                                                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
    }
    #endif
}

extension View {
    /// Re-plans reminders when the app becomes active and after data changes. Attach once at the root.
    func reminderScheduling() -> some View { modifier(ReminderScheduling()) }
}

private struct ReminderScheduling: ViewModifier {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @AppStorage(Prefs.reminderLevel) private var level = ReminderLevel.medium.rawValue
    @AppStorage(Prefs.quietStart) private var quietStart = 22 * 60
    @AppStorage(Prefs.quietEnd) private var quietEnd = 7 * 60
    @State private var tick = 0

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in tick += 1 }
            .onChange(of: phase) { _, p in if p == .active { tick += 1 } }
            .onChange(of: "\(level)\(quietStart)\(quietEnd)") { tick += 1 }
            .task(id: tick) {
                try? await Task.sleep(for: .seconds(2)) // debounce bursts of saves
                guard !Task.isCancelled else { return }
                Autopilot.run(context) // "Automatic": payday and Moonee's plans (spec §4.6)
                await Reminders.refresh(context)
            }
    }
}
