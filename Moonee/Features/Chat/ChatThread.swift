import Foundation
import SwiftData

/// One conversation with Moonee. A new one starts on the first message of each day, or when the user asks.
/// Deleting it deletes its messages, never the transactions they made (those live in the ledger).
@Model final class ChatThread {
    /// A manual chat's name: the first sentence, then a short model-written title when a model is set up.
    var title: String = ""
    /// Started with "New chat". The daily thread is named after its day instead.
    var isManual: Bool = false
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

    /// "Transactions 06/11/26" for the day's thread; a manual chat's own title.
    var displayTitle: String {
        isManual ? (title.isEmpty ? String(localized: "New chat", table: "Chat") : title) : ChatThreads.dailyTitle(day)
    }
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

    /// What the chat shows when it appears, returns to the foreground or passes midnight (`lastCheck` = the previous check).
    /// Within a day the open thread stays, even one reopened from history; once the day changed, today's thread takes over
    /// (nil = today's starts with the first message) and the old one stays in history.
    static func onScreen(open: ChatThread?, resumed: Bool, lastCheck: Date, now: Date = .now, calendar: Calendar = .current,
                         in context: ModelContext) -> (thread: ChatThread?, resumed: Bool) {
        if let open, calendar.isDate(lastCheck, inSameDayAs: now) || calendar.isDate(open.day, inSameDayAs: now) { return (open, resumed) }
        return (todays(now: now, calendar: calendar, in: context), false)
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
        t.isManual = true
        context.insert(t)
        return t
    }

    /// Adds a message; a manual chat's first user message titles it.
    static func add(_ message: ChatMessage, to thread: ChatThread) {
        message.thread = thread
        if thread.title.isEmpty, message.fromUser { thread.title = title(from: message.text) }
    }

    /// "Transactions dd/MM/yy" (vi: "Ghi nhận giao dịch dd/MM/yy"), the same digits in every language.
    nonisolated static func dailyTitle(_ day: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "dd/MM/yy"
        let date = f.string(from: day)
        return String(localized: "Transactions \(date)", table: "Chat")
    }

    /// A manual chat's short title from its first message, written by the model the chat uses. Nil = keep the rule title.
    static func modelTitle(for text: String, using llm: (any LLM)?) async -> String? {
        guard let llm, let raw = try? await llm.complete(
            system: "Write a 2 to 5 word title for a personal-finance chat that starts with the user's message. "
                + "Use the message's language. Reply with the title only: no quotes, no period.",
            user: text) else { return nil }
        let line = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clean = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’.*# ").union(.whitespaces))
        return clean.isEmpty ? nil : title(from: clean)
    }

    /// The first sentence, at most 40 characters on a word boundary.
    nonisolated static func title(from text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let sentence = first.split(separator: /[.!?](\s|$)/).first.map(String.init) ?? first
        let line = sentence.trimmingCharacters(in: .whitespaces)
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
                q.isEmpty || t.displayTitle.localizedStandardContains(q) || (t.messages ?? []).contains { $0.text.localizedStandardContains(q) }
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
