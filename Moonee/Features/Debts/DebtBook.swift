import EventKit
import EventKitUI
import SwiftData
import SwiftUI

func dloc(_ key: String.LocalizationValue) -> String { String(localized: key, table: "Debts") }

/// The debt book (spec §4.5): every write, and each debt's numbers from `Ledger`. Chat, Budget and Account use it.
@MainActor enum DebtBook {
    struct Line: Identifiable {
        let debt: Debt
        /// Still owed, from the ledger (0 once repaid or closed by hand).
        let remaining: Int
        /// Everything lent or borrowed on it.
        let total: Int
        var id: PersistentIdentifier { debt.persistentModelID }
        var isOpen: Bool { remaining > 0 }
        var theyOweMe: Bool { debt.direction == .lent }
    }

    static func lines(_ debts: [Debt], txns: [Txn]) -> [Line] {
        let ledger = Ledger(txns: txns, wallets: [], jars: [])
        return debts.map { d in
            let total = (d.txns ?? []).filter { $0.kind == .lend || $0.kind == .borrow }.reduce(0) { $0 + $1.amount }
            return Line(debt: d, remaining: max(ledger.debtRemaining[d.persistentModelID] ?? 0, 0), total: total)
        }
    }

    static func line(_ debt: Debt, in context: ModelContext) -> Line {
        lines([debt], txns: (try? context.fetch(FetchDescriptor<Txn>())) ?? [])[0]
    }

    /// The open debt with this person: `direction` nil (a repayment) takes either side. Closed debts are history:
    /// lending to Nam again after closing starts a new one.
    static func find(_ person: String, _ direction: DebtDirection?, in debts: [Debt]) -> Debt? {
        debts.first { $0.settledAt == nil && $0.person.localizedCaseInsensitiveCompare(person) == .orderedSame
            && (direction == nil || $0.direction == direction) }
    }

    /// "Ghi nhận trả": they paid me back (money into `wallet`) or I paid them (money out). Partial is fine.
    @discardableResult
    static func repay(_ debt: Debt, amount: Int, wallet: Wallet?, date: Date = .now, in context: ModelContext) -> Txn {
        let t = Txn(amount: amount, kind: .repay, currencyCode: debt.currencyCode, date: date, wallet: wallet)
        context.insert(t)
        t.debt = debt
        t.allocate(jars: (try? context.fetch(FetchDescriptor<Jar>())) ?? [], in: context)
        try? context.save()
        return t
    }

    /// Closes a debt with money still owed (forgiven, called even): no money moves.
    static func close(_ debt: Debt, in context: ModelContext) {
        debt.settledAt = .now
        try? context.save()
    }

    static func reopen(_ debt: Debt, in context: ModelContext) {
        debt.settledAt = nil
        try? context.save()
    }

    /// The chat's quick replies to "When will Nam pay you back?" (nil date = no due date). "Pick a date…" opens a picker.
    nonisolated static func dueChoices(now: Date, calendar: Calendar) -> [(title: String, date: Date?)] {
        let today = calendar.startOfDay(for: now)
        // The coming Sunday (a week on when today is Sunday); the last day of the month (next month's on the last day).
        let sunday = calendar.nextDate(after: today, matching: DateComponents(weekday: 1), matchingPolicy: .nextTime)!
        var month = calendar.dateInterval(of: .month, for: now)!
        if calendar.date(byAdding: .day, value: -1, to: month.end)! <= today { month = calendar.dateInterval(of: .month, for: month.end)! }
        return [(String(localized: "This weekend", table: "Chat"), sunday),
                (String(localized: "End of month", table: "Chat"), calendar.date(byAdding: .day, value: -1, to: month.end)!),
                (String(localized: "No due date", table: "Chat"), nil)]
    }

    /// The chip the user tapped or typed, in any app language ("cuối tháng" with an English UI too).
    /// Outer nil = no chip in `input`; inner nil = no due date.
    nonisolated static func dueChoice(in input: String, now: Date, calendar: Calendar) -> Date?? {
        let keys = ["This weekend", "End of month", "No due date"]
        let bundles = ["en", "vi", "th", "lo"].compactMap { Bundle.main.path(forResource: $0, ofType: "lproj").flatMap(Bundle.init(path:)) }
        let choices = dueChoices(now: now, calendar: calendar)
        for (i, key) in keys.enumerated() {
            let titles = [choices[i].title] + bundles.map { $0.localizedString(forKey: key, value: key, table: "Chat") }
            if titles.contains(where: { input.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) { return .some(choices[i].date) }
        }
        return nil
    }

    /// Words that make "<name> …" a repayment when that name has an open debt ("Nam trả 200k", "Nam paid back 200k").
    // ponytail: a short list across the four languages; move into `Lexicon` if more languages need it.
    nonisolated static let repayWords = ["trả", "tra", "paid", "pays", "returned", "คืน", "ສົ່ງຄືນ", "ຄືນ"]

    nonisolated static var pickDateTitle: String { String(localized: "Pick a date…", table: "Chat") }
}

// MARK: - Budget section

/// The Budget tab's one debt row (P0-3): "Debt book · to collect 800k · to pay back 2tr", opening the debt book.
struct DebtsSection: View {
    @Query(sort: \Debt.createdAt) private var debts: [Debt]
    @Query private var txns: [Txn]
    @Environment(\.balanceHidden) private var hidden

    var body: some View {
        let open = DebtBook.lines(debts, txns: txns).filter(\.isOpen)
        let owed = open.filter(\.theyOweMe).reduce(0) { $0 + $1.remaining }
        let owing = open.filter { !$0.theyOweMe }.reduce(0) { $0 + $1.remaining }
        let money = { (m: Int) in hidden ? AmountFormat.mask : AmountFormat.string(m, Money.defaultCurrency, short: true) }
        let parts = (owed > 0 ? ["\(dloc("To collect")) \(money(owed))"] : []) + (owing > 0 ? ["\(dloc("To pay back")) \(money(owing))"] : [])
        NavigationLink(value: BudgetRoute.debts) {
            BudgetRow(title: dloc("Debt book"), symbol: "person.2.fill") {
                Text(parts.isEmpty ? dloc("No open debts") : parts.joined(separator: " · ")).foregroundStyle(Color.inkSecondary)
            } value: {
                EmptyView()
            }
        }
    }
}

// MARK: - List

/// "Sổ nợ": open debts in two groups, settled ones folded below.
struct DebtBookView: View {
    @Query(sort: \Debt.createdAt, order: .reverse) private var debts: [Debt]
    @Query private var txns: [Txn]
    @State private var showSettled = false

    var body: some View {
        let lines = DebtBook.lines(debts, txns: txns)
        let open = lines.filter(\.isOpen).sorted { ($0.debt.dueDate ?? .distantFuture) < ($1.debt.dueDate ?? .distantFuture) }
        let settled = lines.filter { !$0.isOpen }
        List {
            if lines.isEmpty {
                ContentUnavailableView {
                    Label(dloc("No debts yet"), systemImage: "person.2")
                } description: {
                    Text(dloc("Tell Moonee “lent Nam 500k” or “borrowed 2tr from Lan” and it shows up here, with a reminder when it's due."))
                }
            }
            group(dloc("To collect"), open.filter(\.theyOweMe))
            group(dloc("To pay back"), open.filter { !$0.theyOweMe })
            if !settled.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showSettled) {
                        ForEach(settled) { row($0) }
                    } label: {
                        Text(String(localized: "Settled (\(settled.count))", table: "Debts")).foregroundStyle(Color.ink)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .navigationTitle(dloc("Debt book"))
    }

    @ViewBuilder private func group(_ title: String, _ lines: [DebtBook.Line]) -> some View {
        if !lines.isEmpty {
            Section {
                ForEach(lines) { row($0) }
            } header: {
                Text(title)
            } footer: {
                Text(String(localized: "Total \(AmountFormat.string(lines.reduce(0) { $0 + $1.remaining }, Money.defaultCurrency))", table: "Debts"))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func row(_ l: DebtBook.Line) -> some View {
        NavigationLink { DebtDetailView(debt: l.debt) } label: { DebtRow(line: l) }
    }
}

private struct DebtRow: View {
    let line: DebtBook.Line

    var body: some View {
        let d = line.debt
        BudgetRow(title: d.person, symbol: line.theyOweMe ? "arrow.up.right.circle.fill" : "arrow.down.left.circle.fill",
                  tint: line.isOpen ? (line.theyOweMe ? .income : .danger) : .inkSecondary) {
            DueLabel(debt: d, open: line.isOpen)
        } value: {
            AmountText(line.isOpen ? line.remaining : line.total, currency: d.currencyCode)
                .foregroundStyle(line.isOpen ? Color.ink : Color.inkSecondary)
        }
    }
}

/// "Due 30/11", "Overdue · 2/11", "No due date", or "Settled".
private struct DueLabel: View {
    let debt: Debt
    let open: Bool

    var body: some View {
        if !open {
            Text(dloc("Settled")).foregroundStyle(Color.inkSecondary)
        } else if let due = debt.dueDate {
            let overdue = due < Calendar.current.startOfDay(for: .now)
            let day = due.formatted(.dateTime.day().month())
            Text(overdue ? String(localized: "Overdue · \(day)", table: "Debts") : String(localized: "Due \(day)", table: "Debts"))
                .foregroundStyle(overdue ? Color.danger : Color.inkSecondary)
        } else {
            Text(dloc("No due date")).foregroundStyle(Color.inkSecondary)
        }
    }
}

// MARK: - Detail

struct DebtDetailView: View {
    let debt: Debt
    @Environment(\.modelContext) private var context
    @Query private var txns: [Txn] // redraws the numbers after a repayment
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @State private var repaying = false
    @State private var confirmSettle = false
    @State private var calendarEvent: CalendarDraft?

    var body: some View {
        let line = DebtBook.lines([debt], txns: txns)[0]
        let history = (debt.txns ?? []).sorted { $0.date > $1.date }
        List {
            Section {
                LabeledContent(line.theyOweMe ? dloc("Still owes you") : dloc("You still owe")) {
                    AmountText(line.remaining, currency: debt.currencyCode)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(line.isOpen ? (line.theyOweMe ? Color.income : Color.danger) : Color.inkSecondary)
                }
                LabeledContent(line.theyOweMe ? dloc("Lent in total") : dloc("Borrowed in total")) {
                    AmountText(line.total, currency: debt.currencyCode).foregroundStyle(Color.ink)
                }
                if debt.settledAt != nil {
                    Label(dloc("Closed without full repayment."), systemImage: "checkmark.seal").foregroundStyle(Color.inkSecondary)
                }
            }

            if line.isOpen {
                Section {
                    Button(dloc("Record a repayment"), systemImage: "arrow.uturn.backward.circle") { repaying = true }
                    dueDateRows
                    if let due = debt.dueDate {
                        Button(dloc("Add to Calendar"), systemImage: "calendar.badge.plus") { calendarEvent = .init(debt: debt, due: due, line: line) }
                    }
                    Button(dloc("Mark settled"), systemImage: "checkmark.circle") { confirmSettle = true }
                } footer: {
                    Text(debt.dueDate == nil ? dloc("No due date: Moonee checks in every couple of weeks.")
                                             : dloc("Moonee reminds you on the due day."))
                }
            } else if debt.settledAt != nil {
                Section { Button(dloc("Reopen"), systemImage: "arrow.counterclockwise") { DebtBook.reopen(debt, in: context) } }
            }

            Section(dloc("History")) {
                ForEach(history) { t in
                    LabeledContent {
                        AmountText(t.amount, currency: t.currencyCode).foregroundStyle(Color.ink)
                    } label: {
                        Text(t.note.isEmpty ? t.kind.title : t.note).foregroundStyle(Color.ink)
                        Text(t.date, format: .dateTime.day().month().year())
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .navigationTitle(debt.person)
        .sheet(isPresented: $repaying) { RepaySheet(debt: debt, remaining: line.remaining) }
        .sheet(item: $calendarEvent) { CalendarEventSheet(draft: $0).ignoresSafeArea() }
        .confirmationDialog(dloc("Mark settled"), isPresented: $confirmSettle, titleVisibility: .hidden) {
            Button(String(localized: "Paid back in full (\(AmountFormat.string(line.remaining, debt.currencyCode)))", table: "Debts")) {
                DebtBook.repay(debt, amount: line.remaining, wallet: wallets.first, in: context)
            }
            Button(dloc("Close without payment")) { DebtBook.close(debt, in: context) }
        } message: {
            Text(dloc("Paid back records the money in your wallet. Closing without payment just ends the debt."))
        }
    }

    @ViewBuilder private var dueDateRows: some View {
        Toggle(isOn: Binding { debt.dueDate != nil } set: { on in
            debt.dueDate = on ? Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: .now)) : nil
            try? context.save()
        }) {
            Label(dloc("Due date"), systemImage: "calendar")
        }
        if let due = debt.dueDate {
            DatePicker(dloc("Pay back by"), selection: Binding { due } set: { debt.dueDate = $0; try? context.save() }, displayedComponents: .date)
        }
    }
}

/// How much came back (or went out), into or from which wallet, when.
private struct RepaySheet: View {
    let debt: Debt
    let remaining: Int
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @State private var amount: Int
    @State private var wallet: Wallet?
    @State private var date = Date.now

    init(debt: Debt, remaining: Int) {
        self.debt = debt
        self.remaining = remaining
        _amount = State(initialValue: remaining)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AmountField(title: dloc("Amount"), minor: $amount, currency: debt.currencyCode)
                    Picker(debt.direction == .lent ? dloc("Into wallet") : dloc("From wallet"), selection: $wallet) {
                        ForEach(wallets) { Text($0.name).tag(Optional($0)) }
                    }
                    DatePicker(dloc("Date"), selection: $date, displayedComponents: .date)
                } footer: {
                    Text(String(localized: "Left after this: \(AmountFormat.string(max(remaining - amount, 0), debt.currencyCode))", table: "Debts"))
                }
            }
            .navigationTitle(dloc("Record a repayment"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(dloc("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(dloc("Save")) {
                        DebtBook.repay(debt, amount: amount, wallet: wallet, date: date, in: context)
                        dismiss()
                    }
                    .disabled(amount <= 0)
                }
            }
            .onAppear { if wallet == nil { wallet = wallets.first } }
        }
        .presentationDetents([.medium])
    }
}

/// What goes on the calendar: an all-day event on the due date.
private struct CalendarDraft: Identifiable {
    let id = UUID()
    let title: String
    let due: Date

    @MainActor init(debt: Debt, due: Date, line: DebtBook.Line) {
        let amount = AmountFormat.string(line.remaining, debt.currencyCode)
        title = line.theyOweMe ? String(localized: "\(debt.person) pays back \(amount)", table: "Debts")
                               : String(localized: "Pay \(debt.person) back \(amount)", table: "Debts")
        self.due = due
    }
}

/// The system "New Event" sheet. Since iOS 17 it runs out of process and saves the event itself, so Moonee asks for
/// no calendar permission at all; the user taps Add (or Cancel) there.
private struct CalendarEventSheet: UIViewControllerRepresentable {
    let draft: CalendarDraft
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let e = EKEvent(eventStore: store)
        e.title = draft.title
        e.startDate = draft.due
        e.endDate = draft.due
        e.isAllDay = true
        e.addAlarm(EKAlarm(relativeOffset: 9 * 3600)) // 9:00 that day
        let vc = EKEventEditViewController()
        vc.eventStore = store
        vc.event = e
        vc.editViewDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: EKEventEditViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) { dismiss() }
    }
}
