import BackgroundTasks
import Foundation
import SwiftData

/// Daily classification + month-end reports. Called on app open, from "Chạy ngay" and from background refresh.
@MainActor enum Accountant {
    static let refreshTaskID = "com.haiquan.moonee.accountant.refresh"
    static let summaryKey = "ai.lastSummary"
    static let lastRunKey = "ai.lastRun"
    private static var running = false

    /// App open / background: classify, then make last month's report if it is missing.
    static func runDaily(_ container: ModelContainer) async {
        let context = container.mainContext
        scheduleRefresh()
        guard (try? LLMSettings.current()) != nil else { return } // not set up yet: stay quiet
        _ = try? await classifyPending(context)
        let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: .now)!
        await reportIfMissing(month: lastMonth, context: context)
    }

    static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        req.earliestBeginDate = .now.addingTimeInterval(6 * 3600)
        try? BGTaskScheduler.shared.submit(req)
    }

    // MARK: Classification

    /// Classifies every txn without a category and stores a short summary for today.
    @discardableResult
    static func classifyPending(_ context: ModelContext) async throws -> String {
        guard !running else { throw LLMError("AI đang chạy") }
        running = true
        defer { running = false }

        let llm = try LLMSettings.current()
        let pending = try context.fetch(FetchDescriptor<Txn>(predicate: #Predicate { $0.category == nil }, sortBy: [SortDescriptor(\.date)]))
        let categories = try context.fetch(FetchDescriptor<Category>(sortBy: [SortDescriptor(\.name)]))
        let expense = categories.filter { $0.kind == .expense }.map(\.name)
        let income = categories.filter { $0.kind == .income }.map(\.name)

        var classified = 0
        var suggestions: [String] = []
        var unusual: [String] = []
        var firstError: Error?
        // ponytail: 20 per request keeps prompts inside the on-device 4k context; sequential, fine for daily volume
        for start in stride(from: 0, to: pending.count, by: 20) {
            let batch = Array(pending[start..<min(start + 20, pending.count)])
            let items = batch.enumerated().map { i, t in
                Classifier.Item(id: i + 1, text: [t.rawInput, t.note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                                amount: t.amount, kind: t.kind)
            }
            do {
                let reply = try await llm.complete(system: AccountantSkill.current,
                                                   user: Classifier.prompt(items: items, expense: expense, income: income))
                let result = try Classifier.parse(reply, items: items, expense: expense, income: income)
                for (id, name) in result.assigned {
                    batch[id - 1].category = categories.first { $0.name == name && $0.kind == batch[id - 1].kind }
                    classified += 1
                }
                suggestions += result.suggestions
                unusual += result.unusual.sorted { $0.key < $1.key }.map { id, reason in
                    let t = batch[id - 1]
                    return "\(t.note.isEmpty ? (t.rawInput ?? "") : t.note) \(t.amount.vnd)\(reason.isEmpty ? "" : " – \(reason)")"
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        try context.save()

        let today = Calendar.current.dateInterval(of: .day, for: .now)!
        let (dayStart, dayEnd) = (today.start, today.end)
        let spentToday = try context.fetch(FetchDescriptor<Txn>(predicate: #Predicate { $0.date >= dayStart && $0.date < dayEnd }))
            .filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount }

        var lines = [pending.isEmpty ? "Không có giao dịch cần phân loại." : "Đã phân loại \(classified)/\(pending.count) giao dịch.",
                     "Hôm nay chi \(spentToday.vnd)."]
        if !unusual.isEmpty { lines.append("Bất thường: " + unusual.joined(separator: "; ")) }
        if !suggestions.isEmpty {
            lines.append("AI đề xuất danh mục mới (chưa thêm): " + Array(Set(suggestions)).sorted().joined(separator: ", "))
        }
        if let firstError { lines.append("Lỗi: \(firstError.localizedDescription)") }
        let summary = lines.joined(separator: "\n")
        UserDefaults.standard.set(summary, forKey: summaryKey)
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: lastRunKey)
        if classified == 0, let firstError { throw firstError }
        return summary
    }

    // MARK: Reports

    static func reportIfMissing(month: Date, context: ModelContext) async {
        let interval = Calendar.current.dateInterval(of: .month, for: month)!
        let (start, end) = (interval.start, interval.end)
        let existing = (try? context.fetchCount(FetchDescriptor<MonthlyReport>(predicate: #Predicate { $0.month == start }))) ?? 0
        let txns = (try? context.fetchCount(FetchDescriptor<Txn>(predicate: #Predicate { $0.date >= start && $0.date < end }))) ?? 0
        guard existing == 0, txns > 0 else { return }
        await generateReport(month: month, context: context)
    }

    /// Builds (or rebuilds) the report for `month`: Swift numbers + AI advice.
    @discardableResult
    static func generateReport(month: Date, context: ModelContext) async -> MonthlyReport {
        let txns = (try? context.fetch(FetchDescriptor<Txn>())) ?? []
        let jars = (try? context.fetch(FetchDescriptor<Jar>(sortBy: [SortDescriptor(\.order)]))) ?? []
        let numbers = ReportNumbers(
            lines: txns.map { .init(amount: $0.amount, kind: $0.kind, date: $0.date, note: $0.note,
                                    category: $0.category?.name, jar: $0.category?.jar?.name) },
            jars: jars.map { ($0.name, $0.percent) },
            month: month)

        let advice: String
        do {
            advice = try await LLMSettings.current().complete(system: AccountantSkill.current, user: """
            Số liệu tài chính tháng \(numbers.title) của tôi (đã tính sẵn, chính xác):

            \(numbers.markdown)

            Hãy viết bằng markdown, tối đa 200 từ: 2–3 nhận xét chính về tháng này (điểm tốt, điểm cần chú ý, lọ nào vượt mục tiêu), \
            rồi 3 lời khuyên cụ thể cho tháng tới dạng gạch đầu dòng. Chỉ dùng các số ở trên, không bịa thêm số liệu. Không dùng tiêu đề.
            """)
        } catch {
            advice = "_Chưa có lời khuyên: \(error.localizedDescription)_"
        }

        let start = numbers.month.start
        let markdown = numbers.markdown + "\n\n## Nhận xét & lời khuyên tháng tới\n" + advice.trimmingCharacters(in: .whitespacesAndNewlines)
        if let old = try? context.fetch(FetchDescriptor<MonthlyReport>(predicate: #Predicate { $0.month == start })).first {
            old.markdown = markdown
            old.createdAt = .now
            return old
        }
        let report = MonthlyReport(month: start, markdown: markdown)
        context.insert(report)
        try? context.save()
        return report
    }
}
