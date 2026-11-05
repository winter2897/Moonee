import Foundation
import SwiftData

/// One conversation with Moonee. A new one starts on the first message of each day, or when the user asks.
/// Deleting it deletes its messages, never the transactions they made (those live in the ledger).
@Model final class ChatThread {
    var title: String = ""
    /// Start of the local day it belongs to.
    var day: Date = Date.now
    var isPinned: Bool = false
    var createdAt: Date = Date.now
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.thread) var messages: [ChatMessage]? = []

    init(day: Date, createdAt: Date = .now) {
        self.day = day
        self.createdAt = createdAt
    }

    var sortedMessages: [ChatMessage] { (messages ?? []).sorted { $0.date < $1.date } }
}

/// The rules of threads, kept out of the views so they are testable with a pinned clock and calendar.
@MainActor enum ChatThreads {
    /// The thread a new message goes into. The open thread keeps going on the day it belongs to, or when the user
    /// reopened it from history (`resumed`); otherwise today's latest thread, or a new one: a new day starts a new thread.
    static func forNewMessage(open: ChatThread?, resumed: Bool, now: Date = .now, calendar: Calendar = .current,
                              in context: ModelContext) -> ChatThread {
        if let open, resumed || calendar.isDate(open.day, inSameDayAs: now) { return open }
        let today = calendar.startOfDay(for: now)
        if let latest = todays(now: now, calendar: calendar, in: context) { return latest }
        let t = ChatThread(day: today, createdAt: now)
        context.insert(t)
        return t
    }

    /// The newest thread of today, if any (what the chat shows when it opens).
    static func todays(now: Date = .now, calendar: Calendar = .current, in context: ModelContext) -> ChatThread? {
        let today = calendar.startOfDay(for: now)
        let threads = (try? context.fetch(FetchDescriptor<ChatThread>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        return threads.first { calendar.isDate($0.day, inSameDayAs: today) }
    }

    /// "New chat": an empty thread for today, even if today already has one.
    static func start(now: Date = .now, calendar: Calendar = .current, in context: ModelContext) -> ChatThread {
        let t = ChatThread(day: calendar.startOfDay(for: now), createdAt: now)
        context.insert(t)
        return t
    }

    /// Adds a message; the thread's first user message titles it.
    static func add(_ message: ChatMessage, to thread: ChatThread) {
        message.thread = thread
        if thread.title.isEmpty, message.fromUser { thread.title = title(from: message.text) }
    }

    /// The first line, at most 40 characters on a word boundary.
    // ponytail: rule-based title; ask the model for a summary once titles matter more.
    nonisolated static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard line.count > 40 else { return line }
        let cut = line.prefix(40)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }

    /// Messages saved before threads existed: one thread per day, titled from that day's first user message.
    static func migrate(calendar: Calendar = .current, in context: ModelContext) {
        let loose = ((try? context.fetch(FetchDescriptor<ChatMessage>(sortBy: [SortDescriptor(\.date)]))) ?? []).filter { $0.thread == nil }
        guard !loose.isEmpty else { return }
        for (day, messages) in Dictionary(grouping: loose, by: { calendar.startOfDay(for: $0.date) }) {
            let t = ChatThread(day: day, createdAt: messages.map(\.date).min() ?? day)
            context.insert(t)
            for m in messages.sorted(by: { $0.date < $1.date }) { add(m, to: t) }
        }
    }

    struct Section: Identifiable {
        enum Kind: Hashable { case pinned, day(Date) }
        let kind: Kind
        let threads: [ChatThread]
        var id: Kind { kind }
    }

    /// History list: pinned first, then by day (newest first). `query` matches titles and message text.
    static func sections(_ threads: [ChatThread], query: String = "", calendar: Calendar = .current) -> [Section] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let found = threads
            .filter { !($0.messages ?? []).isEmpty }
            .filter { t in
                q.isEmpty || t.title.localizedStandardContains(q) || (t.messages ?? []).contains { $0.text.localizedStandardContains(q) }
            }
            .sorted { $0.createdAt > $1.createdAt }
        var out: [Section] = []
        let pinned = found.filter(\.isPinned)
        if !pinned.isEmpty { out.append(Section(kind: .pinned, threads: pinned)) }
        let byDay = Dictionary(grouping: found.filter { !$0.isPinned }) { calendar.startOfDay(for: $0.day) }
        for day in byDay.keys.sorted(by: >) { out.append(Section(kind: .day(day), threads: byDay[day] ?? [])) }
        return out
    }
}
