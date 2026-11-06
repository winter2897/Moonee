import SwiftUI

/// Recurring bill state (spec §4.3, §E: upcoming / today / overdue / paid).
enum BillStatus: Equatable {
    case upcoming(days: Int), today, overdue(days: Int), paid

    init(due: Date, paid: Bool, now: Date = .now, calendar: Calendar = .current) {
        if paid { self = .paid; return }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        self = days > 0 ? .upcoming(days: days) : days == 0 ? .today : .overdue(days: -days)
    }

    var label: Text {
        switch self {
        case .upcoming(let d): Text("In \(d) days", tableName: "Components")
        case .today: Text("Due today", tableName: "Components")
        case .overdue(let d): Text("\(d) days overdue", tableName: "Components")
        case .paid: Text("Paid", tableName: "Components")
        }
    }

    /// Non-colour cue for the states that need attention.
    var symbol: String? {
        switch self {
        case .upcoming: nil
        case .today: "bell.fill"
        case .overdue: "exclamationmark.circle.fill"
        case .paid: "checkmark.circle.fill"
        }
    }

    var urgent: Bool {
        switch self {
        case .today, .overdue: true
        case .upcoming, .paid: false
        }
    }

    var color: Color {
        switch self {
        case .upcoming: .inkSecondary
        case .today: .warningText
        case .overdue: .danger
        case .paid: .brandDeep
        }
    }
}

struct BillCard: View {
    let name: String
    let symbol: String
    let amount: Int
    let currency: String
    let due: Date
    var paid = false
    /// Amount is an estimate (electricity, water…): shown with "≈".
    var estimate = false
    /// Shows a "Mark paid" button while unpaid.
    var onMarkPaid: (() -> Void)? = nil

    private var status: BillStatus { BillStatus(due: due, paid: paid) }

    // ponytail: ICU gives "08-11" in vi; the mockups write "08/11".
    private var dateText: Text { Text(due.formatted(.dateTime.day(.twoDigits).month(.twoDigits)).replacingOccurrences(of: "-", with: "/")) }

    private var statusText: some View {
        HStack(spacing: 4) {
            if let symbol = status.symbol { Image(systemName: symbol) }
            status.label.fontWeight(status.urgent ? .semibold : .regular)
        }
        .foregroundStyle(status.color)
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: symbol, color: paid ? .inkSecondary : .brandDeep)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.rowTitle).foregroundStyle(Color.ink)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { dateText; Text(verbatim: "·"); statusText }
                    VStack(alignment: .leading, spacing: 2) { dateText; statusText }
                }
                .font(.secondaryText)
                .foregroundStyle(Color.inkSecondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 2) {
                    if estimate { Text(verbatim: "≈").accessibilityLabel(Text("about", tableName: "Components")) }
                    AmountText(amount, currency: currency)
                }
                .font(.rowTitle)
                .foregroundStyle(paid ? Color.inkSecondary : Color.ink)
                if let onMarkPaid, !paid {
                    Button(action: onMarkPaid) { Text("Mark paid", tableName: "Components") }
                        .buttonStyle(OutlinePillStyle())
                }
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 16)
        .frame(minHeight: 44)
        .opacity(paid ? 0.6 : 1)
        // No background: a list row. Group bills in one `.card(padding: 0)` with dividers, like JarCard rows.
    }
}
