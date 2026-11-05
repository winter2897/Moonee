import Foundation

/// The read-only view of the user's books that AI tools compute from. Plain values, no SwiftData:
/// the app's store adopts it with a small adapter; tests use an in-memory fake.
/// ponytail: one currency per ledger; convert before handing txns over once multi-currency wallets exist.
protocol LedgerReading: Sendable {
    /// ISO 4217 code all amounts are in.
    var currency: String { get }
    func jars() async throws -> [LedgerJar]
    func transactions(in interval: DateInterval) async throws -> [LedgerTxn]
}

struct LedgerJar: Sendable, Equatable {
    var key: String
    /// Display name in the UI language (or the user's own name).
    var name: String
    var percent: Int
    /// Current envelope balance, minor units (spec §4.1: carries over between months).
    var balance: Int
}

struct LedgerTxn: Sendable, Equatable {
    var date: Date
    /// Minor units, positive; `kind` gives the direction.
    var amount: Int
    var kind: EntryKind
    var categoryKey: String?
    var categoryName: String?
    /// Expense: the jar it came out of. Jar transfer: the source jar.
    var jarKey: String?
    /// Jar transfer: the destination jar.
    var toJarKey: String?
    /// Income: how it was split into jars (jar key → minor units).
    var splits: [String: Int] = [:]
    var note = ""
    var person: String?
}

/// Periods tools understand.
enum LedgerPeriod: String, CaseIterable, Codable, Sendable {
    case today, thisWeek, lastWeek, thisMonth, lastMonth, thisYear, lastYear

    func interval(now: Date, calendar: Calendar) -> DateInterval {
        let (component, back): (Calendar.Component, Int) = switch self {
        case .today: (.day, 0)
        case .thisWeek: (.weekOfYear, 0)
        case .lastWeek: (.weekOfYear, -1)
        case .thisMonth: (.month, 0)
        case .lastMonth: (.month, -1)
        case .thisYear: (.year, 0)
        case .lastYear: (.year, -1)
        }
        let anchor = calendar.date(byAdding: component, value: back, to: now)!
        return calendar.dateInterval(of: component, for: anchor)!
    }

    /// The period of the same length right before.
    func previous(now: Date, calendar: Calendar) -> DateInterval {
        let i = interval(now: now, calendar: calendar)
        let component: Calendar.Component = switch self {
        case .today: .day
        case .thisWeek, .lastWeek: .weekOfYear
        case .thisMonth, .lastMonth: .month
        case .thisYear, .lastYear: .year
        }
        return calendar.dateInterval(of: component, for: i.start.addingTimeInterval(-1))!
    }
}

/// Jar money in and out over some transactions.
struct JarFlows {
    var inflow: [String: Int] = [:]
    var outflow: [String: Int] = [:]

    init(_ txns: [LedgerTxn]) {
        for t in txns {
            switch t.kind {
            case .income: for (jar, v) in t.splits { inflow[jar, default: 0] += v }
            case .expense: if let j = t.jarKey { outflow[j, default: 0] += t.amount }
            case .jarTransfer:
                if let j = t.jarKey { outflow[j, default: 0] += t.amount }
                if let j = t.toJarKey { inflow[j, default: 0] += t.amount }
            case .transfer, .lend, .borrow, .repay: break // spec §4.5: debts and wallet moves never touch jars
            }
        }
    }

    func net(_ jar: String) -> Int { inflow[jar, default: 0] - outflow[jar, default: 0] }
}
