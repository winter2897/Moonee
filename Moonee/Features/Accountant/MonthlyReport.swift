import Foundation
import SwiftData

@Model final class MonthlyReport {
    /// Start of the reported month.
    var month: Date
    var markdown: String
    var createdAt = Date()

    init(month: Date, markdown: String) {
        self.month = month
        self.markdown = markdown
    }
}

/// Month-end numbers, computed in Swift so the LLM only writes prose. Pure, so it is unit-tested.
struct ReportNumbers {
    struct Line {
        let amount: Int
        let kind: TxKind
        let date: Date
        let note: String
        let category: String?
        let jar: String?
    }

    struct Share: Equatable {
        let name: String
        let total: Int
    }

    struct JarRow: Equatable {
        let name: String
        let percent: Int
        let spent: Int
        /// percent × month income; nil when there was no income.
        let target: Int?
    }

    static let uncategorized = "Chưa phân loại"
    static let noJar = "Chưa gán lọ"

    let month: DateInterval
    let title: String
    let income: Int
    let expense: Int
    let previousExpense: Int
    let categories: [Share]
    let jars: [JarRow]
    let unjarred: Int
    let top: [Line]

    /// Percent change vs last month, nil when last month had no spending.
    var change: Int? { previousExpense > 0 ? (expense - previousExpense) * 100 / previousExpense : nil }

    init(lines: [Line], jars jarList: [(name: String, percent: Int)], month anchor: Date, calendar: Calendar = .current) {
        month = calendar.dateInterval(of: .month, for: anchor)!
        let previous = calendar.dateInterval(of: .month, for: month.start.addingTimeInterval(-1))!
        let c = calendar.dateComponents([.month, .year], from: month.start)
        title = "\(c.month!)/\(String(c.year!))"

        func inMonth(_ i: DateInterval, _ kind: TxKind) -> [Line] {
            lines.filter { $0.kind == kind && $0.date >= i.start && $0.date < i.end }
        }
        func sum(_ l: [Line]) -> Int { l.reduce(0) { $0 + $1.amount } }

        let spent = inMonth(month, .expense)
        income = sum(inMonth(month, .income))
        expense = sum(spent)
        previousExpense = sum(inMonth(previous, .expense))
        categories = Dictionary(grouping: spent) { $0.category ?? Self.uncategorized }
            .map { Share(name: $0.key, total: sum($0.value)) }
            .sorted { ($0.total, $1.name) > ($1.total, $0.name) }
        let byJar = Dictionary(grouping: spent) { $0.jar ?? "" }.mapValues(sum)
        let income = income
        jars = jarList.map { JarRow(name: $0.name, percent: $0.percent, spent: byJar[$0.name] ?? 0,
                                    target: income > 0 ? income * $0.percent / 100 : nil) }
        unjarred = expense - jars.reduce(0) { $0 + $1.spent }
        top = Array(spent.sorted { $0.amount > $1.amount }.prefix(5))
    }

    var markdown: String {
        var md = ["## Tổng quan tháng \(title)", "- Thu nhập: **\(income.vnd)**", "- Chi tiêu: **\(expense.vnd)**"]
        if let change {
            md.append("- So với tháng trước (\(previousExpense.vnd)): \(change > 0 ? "tăng" : "giảm") \(abs(change))%")
        }
        md.append("- Còn lại: **\((income - expense).vnd)**")

        md.append("\n## Chi theo danh mục")
        md += categories.map { "- \($0.name): \($0.total.vnd) (\(expense > 0 ? $0.total * 100 / expense : 0)%)" }
        if categories.isEmpty { md.append("- Chưa có chi tiêu") }

        md.append("\n## Theo 6 chiếc lọ")
        for j in jars {
            if let target = j.target {
                md.append("- \(j.name) (\(j.percent)%): \(j.spent.vnd) / mục tiêu \(target.vnd)\(j.spent > target ? " ⚠️ vượt" : "")")
            } else {
                md.append("- \(j.name) (\(j.percent)%): \(j.spent.vnd)")
            }
        }
        if unjarred > 0 { md.append("- \(Self.noJar): \(unjarred.vnd)") }

        if !top.isEmpty {
            md.append("\n## Chi lớn nhất")
            md += top.map { "- \($0.date.formatted(.dateTime.day(.twoDigits).month(.twoDigits))) · \($0.note.isEmpty ? ($0.category ?? Self.uncategorized) : $0.note): \($0.amount.vnd)" }
        }
        return md.joined(separator: "\n")
    }
}
