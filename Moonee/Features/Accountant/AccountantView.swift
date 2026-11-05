import SwiftData
import SwiftUI

struct AccountantView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \MonthlyReport.month, order: .reverse) private var reports: [MonthlyReport]
    @Query(filter: #Predicate<Txn> { $0.category == nil }) private var pending: [Txn]
    @AppStorage(Accountant.summaryKey) private var summary = ""
    @AppStorage(Accountant.lastRunKey) private var lastRun = 0.0
    @State private var busy = false
    @State private var error: String?
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Tóm tắt hôm nay").font(.headline)
                    Spacer()
                    Text("\(pending.count) chưa phân loại").font(.caption).foregroundStyle(.secondary)
                }
                Text(summary.isEmpty ? "AI chưa chạy lần nào." : summary).font(.subheadline)
                if lastRun > 0 {
                    Text("Lần chạy gần nhất: \(Date(timeIntervalSince1970: lastRun).formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    run { try await Accountant.classifyPending(context) }
                } label: {
                    Label(busy ? "Đang chạy…" : "Chạy ngay", systemImage: "sparkles")
                }
                .buttonStyle(MooneeButtonStyle())
                .disabled(busy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Báo cáo tháng").font(.headline)
                    Spacer()
                    Menu("Tạo báo cáo", systemImage: "plus") {
                        Button("Tháng này") { report(monthOffset: 0) }
                        Button("Tháng trước") { report(monthOffset: -1) }
                    }
                    .disabled(busy)
                }
                .padding(.bottom, 6)
                if reports.isEmpty {
                    Text("Báo cáo tháng trước sẽ tự tạo khi sang tháng mới.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(reports) { r in
                    NavigationLink { ReportDetailView(report: r) } label: {
                        HStack {
                            IconBadge(symbol: "doc.text.fill", color: .mooneeGreen, size: 34)
                            Text("Tháng \(r.month.formatted(.dateTime.month(.defaultDigits).year()))")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .foregroundStyle(Color.mooneeInk)
        .mooneeScreen("AI kế toán & Báo cáo")
        .toolbar {
            Button("Cài đặt AI", systemImage: "gearshape") { showSettings = true }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                AccountantSettingsView().toolbar { Button("Xong") { showSettings = false } }
            }
        }
        .alert("Lỗi", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private func report(monthOffset: Int) {
        let month = Calendar.current.date(byAdding: .month, value: monthOffset, to: .now)!
        run { await Accountant.generateReport(month: month, context: context) }
    }

    private func run(_ work: @escaping () async throws -> some Any) {
        busy = true
        Task {
            do { _ = try await work() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct ReportDetailView: View {
    @Environment(\.modelContext) private var context
    let report: MonthlyReport
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(report.markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("#") {
                    Text(inline(line.drop { $0 == "#" })).font(.headline).padding(.top, 10)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(Color.mooneeGreen)
                        Text(inline(line.dropFirst(2)))
                    }
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(inline(Substring(line)))
                }
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .foregroundStyle(Color.mooneeInk)
        .mooneeScreen("Tháng \(report.month.formatted(.dateTime.month(.defaultDigits).year()))")
        .toolbar {
            ShareLink(item: report.markdown)
            Button {
                busy = true
                Task { await Accountant.generateReport(month: report.month, context: context); busy = false }
            } label: {
                if busy { ProgressView() } else { Image(systemName: "arrow.clockwise") }
            }
            .disabled(busy)
        }
    }

    // ponytail: line-based markdown (headings, bullets, inline bold/italic); swap for a renderer if reports get tables
    private func inline(_ s: Substring) -> AttributedString {
        let s = s.trimmingCharacters(in: .whitespaces)
        return (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}
