import SwiftData
import SwiftUI

/// Recurring & bills section of the Budget list (spec §4.3), soonest due first. Swipe right or long-press for "Mark paid"
/// ("Mark received" for a salary: an income recurring, split into the jars when it comes in).
struct BillsSection: View {
    @Binding var sheet: BudgetSheet?
    @Environment(\.modelContext) private var context
    @Query(sort: \Recurring.nextDue) private var bills: [Recurring]
    @Query private var jars: [Jar]

    var body: some View {
        let cal = Calendar.current
        let soon = cal.date(byAdding: .day, value: 30, to: cal.startOfDay(for: .now))!
        let dueSoon = bills.filter { $0.nextDue < soon && !$0.isIncome }
        Section {
            if bills.isEmpty {
                ContentUnavailableView {
                    Label(loc("No bills yet"), systemImage: "calendar")
                } description: {
                    Text(loc("Add rent, electricity, internet or subscriptions and Moonee will remind you before they're due."))
                } actions: {
                    Button(loc("Add bill")) { sheet = .bill(nil) }
                }
            } else {
                LabeledContent(loc("Due in the next 30 days")) {
                    AmountText(dueSoon.reduce(0) { $0 + $1.amount }, currency: Money.defaultCurrency).foregroundStyle(Color.ink)
                }
            }
            ForEach(bills) { b in
                Button { sheet = .bill(b) } label: { BillRow(bill: b) }
                    .swipeActions(edge: .leading) {
                        Button(b.isIncome ? loc("Mark received") : loc("Mark paid"), systemImage: "checkmark") { pay(b) }.tint(Color.brandPrimary)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(loc("Delete"), systemImage: "trash", role: .destructive) { context.delete(b) }
                    }
                    .contextMenu {
                        Button(b.isIncome ? loc("Mark received") : loc("Mark paid"), systemImage: "checkmark.circle") { pay(b) }
                        Button(loc("Edit"), systemImage: "pencil") { sheet = .bill(b) }
                        Button(loc("Delete"), systemImage: "trash", role: .destructive) { context.delete(b) }
                    }
            }
        } header: {
            Text(loc("Recurring & Bills"))
        }
    }

    /// Estimated bills ask for the real amount first.
    private func pay(_ b: Recurring) {
        if b.isEstimate { sheet = .payBill(b) } else { withAnimation { _ = BudgetActions.markPaid(b, jars: jars, in: context) } }
    }
}

/// Name, due state and date, amount. Paid this month shows "Paid · next date".
private struct BillRow: View {
    let bill: Recurring

    var body: some View {
        let paid = bill.lastPaid.map { Calendar.current.isDate($0, equalTo: .now, toGranularity: .month) } ?? false
        let status = BillStatus(due: bill.nextDue, paid: paid)
        let date = Text(bill.nextDue, format: .dateTime.day().month())
        BudgetRow(title: bill.name, symbol: bill.category?.icon ?? "calendar", tint: bill.category?.color ?? .brandDeep) {
            ((status.symbol.map { Text(Image(systemName: $0)) + Text(verbatim: " ") } ?? Text(verbatim: "")) + status.label)
                .foregroundStyle(status.color)
            + Text(verbatim: " · ").foregroundStyle(Color.inkSecondary)
            + (paid ? Text(String(localized: "next \(bill.nextDue.formatted(.dateTime.day().month()))", table: "Budget")) : date)
                .foregroundStyle(Color.inkSecondary)
        } value: {
            VStack(alignment: .trailing, spacing: 2) {
                AmountText(bill.amount, currency: bill.currencyCode, plus: bill.isIncome)
                    .foregroundStyle(bill.isIncome ? Color.income : Color.ink)
                if bill.isEstimate { Text(loc("Estimate")).font(.caption).foregroundStyle(Color.inkSecondary) }
            }
        }
    }
}

/// "Mark paid" for an estimated bill: enter what was actually paid.
struct PayBillSheet: View {
    let bill: Recurring
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var jars: [Jar]
    @State private var amount: Int

    init(bill: Recurring) {
        self.bill = bill
        _amount = State(initialValue: bill.amount)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AmountField(title: loc("Amount"), minor: $amount, currency: bill.currencyCode)
                } footer: {
                    Text(bill.isIncome ? loc("This income varies. Enter what you actually received.")
                                       : loc("This bill is an estimate. Enter what you actually paid."))
                }
            }
            .navigationTitle(bill.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(loc("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(bill.isIncome ? loc("Mark received") : loc("Mark paid")) {
                        BudgetActions.markPaid(bill, amount: amount, jars: jars, in: context)
                        dismiss()
                    }
                    .disabled(amount <= 0)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Add / edit / delete a recurring bill.
struct RecurringForm: View {
    let bill: Recurring?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.order) private var categories: [Category]
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @State private var name = ""
    @State private var amount = 0
    @State private var isEstimate = false
    @State private var frequency = Frequency.monthly
    @State private var nextDue = Date.now
    @State private var remindDaysBefore = 1
    @State private var category: Category?
    @State private var wallet: Wallet?
    @State private var confirmDelete = false

    init(bill: Recurring?) {
        self.bill = bill
        guard let bill else { return }
        _name = State(initialValue: bill.name)
        _amount = State(initialValue: bill.amount)
        _isEstimate = State(initialValue: bill.isEstimate)
        _frequency = State(initialValue: bill.frequency)
        _nextDue = State(initialValue: bill.nextDue)
        _remindDaysBefore = State(initialValue: bill.remindDaysBefore)
        _category = State(initialValue: bill.category)
        _wallet = State(initialValue: bill.wallet)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(loc("Name, e.g. Rent"), text: $name)
                    AmountField(title: loc("Amount"), minor: $amount, currency: bill?.currencyCode ?? Money.defaultCurrency)
                    Toggle(loc("Amount varies (estimate)"), isOn: $isEstimate)
                }
                Section {
                    Picker(loc("Repeats"), selection: $frequency) {
                        ForEach(Frequency.allCases, id: \.self) { Text(title($0)).tag($0) }
                    }
                    DatePicker(loc("Next due"), selection: $nextDue, displayedComponents: .date)
                    Stepper(remindDaysBefore == 0 ? loc("Remind on the due day") : String(localized: "Remind \(remindDaysBefore) days before", table: "Budget"),
                            value: $remindDaysBefore, in: 0...14)
                }
                Section {
                    Picker(loc("Category"), selection: $category) {
                        Text(loc("None")).tag(nil as Category?)
                        ForEach(categories) { Label($0.name, systemImage: $0.icon).tag($0 as Category?) }
                    }
                    Picker(category?.kind == .income ? loc("Paid into") : loc("Pay from"), selection: $wallet) {
                        Text(loc("None")).tag(nil as Wallet?)
                        ForEach(wallets) { Text($0.name).tag($0 as Wallet?) }
                    }
                } footer: {
                    if category?.kind == .income {
                        Text(loc("An income: when it comes in, it is split into your jars by their percents."))
                    } else if let jar = category?.jar {
                        Text(String(localized: "Comes out of the \(jar.name) jar.", table: "Budget"))
                    }
                }
                if bill != nil {
                    Button(loc("Delete bill"), role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle(bill == nil ? loc("New bill") : loc("Edit bill"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(loc("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc("Save"), action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || amount <= 0)
                }
            }
            .confirmationDialog(loc("Delete this bill? Past payments stay in your history."), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(loc("Delete bill"), role: .destructive) {
                    if let bill { context.delete(bill) }
                    dismiss()
                }
            }
            .onAppear { if bill == nil, wallet == nil { wallet = wallets.first } }
        }
    }

    private func title(_ f: Frequency) -> String {
        switch f {
        case .daily: loc("Every day")
        case .weekly: loc("Every week")
        case .monthly: loc("Every month")
        case .yearly: loc("Every year")
        }
    }

    private func save() {
        let b = bill ?? Recurring(name: name, amount: amount, nextDue: nextDue)
        if bill == nil { context.insert(b) }
        b.name = name.trimmingCharacters(in: .whitespaces)
        b.amount = amount
        b.isEstimate = isEstimate
        b.frequency = frequency
        // Only a new due date resets the anchor day (editing a 31st bill in February keeps 31).
        if bill == nil || !Calendar.current.isDate(b.nextDue, inSameDayAs: nextDue) {
            b.dueDay = Calendar.current.component(.day, from: nextDue)
        }
        b.nextDue = nextDue
        b.remindDaysBefore = remindDaysBefore
        b.category = category
        b.wallet = wallet
        dismiss()
    }
}
