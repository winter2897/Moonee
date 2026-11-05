import SwiftData
import SwiftUI

/// Recurring & bills segment (spec §4.3): due/overdue/upcoming bills with "Paid", and what was paid this month.
struct BillsSection: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Recurring.nextDue) private var bills: [Recurring]
    @Query private var jars: [Jar]
    @State private var editing: Recurring?
    @State private var adding = false
    /// Estimated bills ask for the real amount before "Paid" records it.
    @State private var confirming: Recurring?
    @State private var paidAmount: Decimal = 0

    var body: some View {
        let cal = Calendar.current
        let month = cal.dateInterval(of: .month, for: .now)!
        let soon = cal.date(byAdding: .day, value: 30, to: cal.startOfDay(for: .now))!
        let dueSoon = bills.filter { $0.nextDue < soon }
        let paid = bills.filter { $0.lastPaid.map(month.contains) ?? false }
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(loc("Due in the next 30 days")).font(.subheadline.weight(.semibold))
                AmountText(dueSoon.reduce(0) { $0 + $1.amount }, currency: Money.defaultCurrency)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(String(localized: "\(dueSoon.count) due · \(paid.count) paid this month", table: "Budget"))
                    .font(.subheadline).foregroundStyle(Color.inkSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 18)

            BudgetSectionHeader(title: loc("Recurring & Bills")) {
                Button(loc("Add"), systemImage: "plus") { adding = true }.fontWeight(.semibold)
            }
            if bills.isEmpty {
                EmptyState(title: loc("No bills yet"), message: loc("Add rent, electricity, internet or subscriptions and Moonee will remind you before they're due.")) {
                    Button(loc("Add a bill")) { adding = true }.buttonStyle(MooneeButtonStyle()).padding(.top, 4)
                }
            }
            VStack(spacing: 8) {
                ForEach(bills) { b in
                    BillCard(name: b.name, symbol: b.category?.icon ?? "calendar", amount: b.amount, currency: b.currencyCode,
                             due: b.nextDue, estimate: b.isEstimate) { pay(b) }
                        .contentShape(.rect)
                        .onTapGesture { editing = b }
                }
            }
            if !paid.isEmpty {
                BudgetSectionHeader(title: loc("Paid this month")) { EmptyView() }
                VStack(spacing: 8) {
                    ForEach(paid) { b in
                        BillCard(name: b.name, symbol: b.category?.icon ?? "calendar", amount: b.amount, currency: b.currencyCode,
                                 due: b.lastPaid ?? b.nextDue, paid: true)
                    }
                }
            }
        }
        .sheet(isPresented: $adding) { RecurringForm(bill: nil) }
        .sheet(item: $editing) { RecurringForm(bill: $0) }
        .alert(loc("How much was it?"), isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            TextField(loc("Amount"), value: $paidAmount, format: .number).keyboardType(.decimalPad)
            Button(loc("Cancel"), role: .cancel) {}
            Button(loc("Mark paid")) {
                if let b = confirming, paidAmount > 0 {
                    BudgetActions.markPaid(b, amount: Money(major: paidAmount, b.currencyCode).minor, jars: jars, in: context)
                }
            }
        } message: {
            Text(loc("This bill is an estimate. Enter what you actually paid."))
        }
    }

    private func pay(_ b: Recurring) {
        if b.isEstimate {
            paidAmount = Money(b.amount, b.currencyCode).major
            confirming = b
        } else {
            withAnimation { _ = BudgetActions.markPaid(b, jars: jars, in: context) }
        }
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
                        ForEach(categories.filter { $0.kind == .expense }) { Label($0.name, systemImage: $0.icon).tag($0 as Category?) }
                    }
                    Picker(loc("Pay from"), selection: $wallet) {
                        Text(loc("None")).tag(nil as Wallet?)
                        ForEach(wallets) { Text($0.name).tag($0 as Wallet?) }
                    }
                } footer: {
                    if let jar = category?.jar { Text(String(localized: "Comes out of the \(jar.name) jar.", table: "Budget")) }
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
        b.nextDue = nextDue
        b.remindDaysBefore = remindDaysBefore
        b.category = category
        b.wallet = wallet
        dismiss()
    }
}
