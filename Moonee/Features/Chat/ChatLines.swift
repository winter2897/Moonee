import Foundation

/// What Moonee says in the chat: confirmations, questions and errors, like a friend would (en + vi in `Chat.xcstrings`).
/// A few wordings each, so it doesn't repeat itself. Amounts come formatted from Swift (`Money.formatted()`), never the model.
/// The persona in the system prompt is S3's; these are the chat's own templates.
enum ChatLines {
    /// Picks one wording; tests pass `variant` to pin it.
    static func pick(_ options: [String], _ variant: Int? = nil) -> String {
        options[(variant ?? Int.random(in: 0..<options.count)) % options.count]
    }

    // MARK: Saved

    /// "Moonee ghi lại **40.000 ₫** ăn sáng ở GS25 hôm nay rồi nhé." Several transactions are summed up in one line.
    @MainActor static func saved(_ txns: [Txn], calendar: Calendar = .current, variant: Int? = nil) -> String {
        guard let t = txns.first else { return "" }
        if txns.count > 1 {
            let n = txns.count
            let sameKind = Set(txns.map(\.kind)).count == 1, sameCurrency = Set(txns.map(\.currencyCode)).count == 1
            guard sameKind, sameCurrency else {
                return pick([String(localized: "Moonee logged all \(n) for you.", table: "Chat"),
                             String(localized: "Done, \(n) transactions are in your books.", table: "Chat")], variant)
            }
            let total = Money(txns.reduce(0) { $0 + $1.amount }, t.currencyCode).formatted()
            return pick([String(localized: "Moonee logged \(n) transactions, **\(total)** in total.", table: "Chat"),
                         String(localized: "All \(n) are in: **\(total)** altogether.", table: "Chat")], variant)
        }
        let amount = Money(t.amount, t.currencyCode).formatted()
        let what = t.note.isEmpty ? (t.category?.name ?? t.kind.title).lowercased() : midSentence(t.note)
        let when = when(t.date, calendar: calendar)
        switch t.kind {
        case .expense:
            return pick([String(localized: "Moonee noted **\(amount)** for \(what) \(when).", table: "Chat"),
                         String(localized: "Got it, **\(amount)** on \(what) \(when) is in your books.", table: "Chat"),
                         String(localized: "Done! **\(amount)** for \(what) \(when), all saved.", table: "Chat")], variant)
        case .income where (t.splits ?? []).isEmpty: // Suggest: it waits in Unallocated, the card offers the split
            return pick([String(localized: "Nice, **\(amount)** came in from \(what) \(when). It's waiting in Unallocated.", table: "Chat"),
                         String(localized: "Money in! **\(amount)** from \(what) \(when). Split it into your jars below?", table: "Chat")], variant)
        case .income:
            return pick([String(localized: "Nice, **\(amount)** came in from \(what) \(when), split into your jars.", table: "Chat"),
                         String(localized: "Money in! **\(amount)** from \(what) \(when), split into your jars.", table: "Chat")], variant)
        case .transfer:
            let from = t.wallet?.name ?? "", to = t.toWallet?.name ?? ""
            return String(localized: "Moved **\(amount)** from \(from) to \(to).", table: "Chat")
        case .jarTransfer:
            let from = t.jar?.name ?? "", to = t.toJar?.name ?? ""
            return String(localized: "Moved **\(amount)** from the \(from) jar to \(to).", table: "Chat")
        case .lend:
            guard let person = t.debt?.person else { return String(localized: "Noted, you lent out **\(amount)**.", table: "Chat") }
            return String(localized: "Noted, you lent \(person) **\(amount)**.", table: "Chat")
        case .borrow:
            guard let person = t.debt?.person else { return String(localized: "Noted, you borrowed **\(amount)**.", table: "Chat") }
            return String(localized: "Noted, you borrowed **\(amount)** from \(person).", table: "Chat")
        case .repay:
            guard let person = t.debt?.person else { return String(localized: "Noted a repayment of **\(amount)**.", table: "Chat") }
            return String(localized: "Noted, **\(amount)** repaid with \(person).", table: "Chat")
        }
    }

    /// "Ăn sáng ở GS25" reads "ăn sáng ở GS25" inside a sentence; "GS25 cafe" or "ATM" keep their capitals.
    /// A name ("Nguyễn Phước Thịnh", "Highlands Coffee") keeps its capitals too.
    static func midSentence(_ note: String) -> String {
        let words = note.split(whereSeparator: \.isWhitespace)
        let first = words.first ?? ""
        guard first.filter(\.isUppercase).count == 1, first.first?.isUppercase == true,
              words.count < 2 || words[1].first?.isUppercase != true else { return note }
        return note.prefix(1).lowercased() + note.dropFirst()
    }

    /// "today", "yesterday", "on 6/11".
    static func when(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return String(localized: "today", table: "Chat") }
        if calendar.isDateInYesterday(date) { return String(localized: "yesterday", table: "Chat") }
        let day = date.formatted(.dateTime.day().month(.defaultDigits))
        return String(localized: "on \(day)", table: "Chat")
    }

    // MARK: Questions

    static func question(_ field: ParsedTxn.Field, _ p: ParsedTxn, variant: Int? = nil) -> String {
        switch field {
        case .toWallet:
            return pick([String(localized: "Which wallet did the money go to?", table: "Chat"),
                         String(localized: "Where did it go? Pick a wallet below.", table: "Chat")], variant)
        case .jar:
            return pick([String(localized: "Which jar should Moonee take it from?", table: "Chat"),
                         String(localized: "Take it out of which jar?", table: "Chat")], variant)
        case .toJar:
            return pick([String(localized: "Which jar should it go into?", table: "Chat"),
                         String(localized: "And which jar does it land in?", table: "Chat")], variant)
        case .kind:
            let amount = Money(p.amount ?? 0, p.currency).formatted()
            if p.kind == .income {
                guard let person = p.person else {
                    return String(localized: "**\(amount)** came in. Was it income, a loan to you, or someone paying you back?", table: "Chat")
                }
                return String(localized: "Got **\(amount)** from \(person). Income, a loan to you, or them paying you back?", table: "Chat")
            }
            guard let person = p.person else {
                return String(localized: "Sent **\(amount)**. Was it spending, a loan, or paying back a debt?", table: "Chat")
            }
            return String(localized: "Sent **\(amount)** to \(person). Spending, a loan, or paying back a debt?", table: "Chat")
        case .dueDate:
            let person = p.person ?? ""
            return p.kind == .borrow
                ? pick([String(localized: "When do you plan to pay \(person) back?", table: "Chat"),
                        String(localized: "When will you pay \(person) back? Moonee will remind you.", table: "Chat")], variant)
                : pick([String(localized: "When will \(person) pay you back?", table: "Chat"),
                        String(localized: "When did \(person) say they'd pay you back? Moonee will remind you.", table: "Chat")], variant)
        case .amount, .person:
            let what = p.note.trimmingCharacters(in: .whitespaces)
            if what.isEmpty {
                return pick([String(localized: "How much was it? Just the number is fine, like 45k.", table: "Chat"),
                             String(localized: "What was the amount? Something like 45k works.", table: "Chat")], variant)
            }
            return pick([String(localized: "How much was **\(what)**? Just the number is fine, like 45k.", table: "Chat"),
                         String(localized: "How much did **\(what)** cost? Something like 45k works.", table: "Chat")], variant)
        }
    }

    /// The due date Moonee just saved for a loan.
    static func dueSaved(_ p: ParsedTxn, calendar: Calendar = .current) -> String {
        guard let due = p.dueDate else {
            return String(localized: "Got it, no due date. Moonee will check in every couple of weeks.", table: "Chat")
        }
        let day = due.formatted(.dateTime.weekday(.wide).day().month(.defaultDigits))
        return String(localized: "Okay, due \(day). Moonee will remind you that morning.", table: "Chat")
    }

    /// After a repayment: what's left on that debt.
    static func debtLeft(person: String, theyOweMe: Bool, left: String?) -> String {
        guard let left else { return String(localized: "All settled with \(person)!", table: "Chat") }
        return theyOweMe ? String(localized: "\(person) still owes you **\(left)**.", table: "Chat")
                         : String(localized: "You still owe \(person) **\(left)**.", table: "Chat")
    }

    static var oneWallet: String {
        String(localized: "You only have one wallet so far. Add another in Budget, then tell Moonee again.", table: "Chat")
    }

    // MARK: Errors

    static func confused(variant: Int? = nil) -> String {
        pick([String(localized: "Hmm, Moonee didn't quite get that. Try something like “phở 45k” or “how much did I spend this month?”", table: "Chat"),
              String(localized: "Sorry, that one slipped past Moonee. Something like “coffee 30k” or “what's left in my jars?” works.", table: "Chat")], variant)
    }

    static var unreadableReceipt: String {
        String(localized: "Moonee couldn't read that receipt. Try again with the whole receipt in good light.", table: "Chat")
    }

    static var notMoney: String {
        String(localized: "Moonee doesn't see a receipt, transfer or bill in that photo, so nothing was saved.", table: "Chat")
    }

    static var alreadyRecorded: String {
        String(localized: "Moonee already has that one in your books (same transaction ID), so it wasn't saved again.", table: "Chat")
    }

    static var unreadableFile: String {
        String(localized: "Moonee couldn't open that file. Try a photo or a PDF of the receipt.", table: "Chat")
    }

    static func voice(_ failure: SpeechInput.Failure) -> String {
        switch failure {
        case .denied:
            String(localized: "Moonee needs the microphone and speech recognition to hear you. Turn them on in Settings › Moonee.", table: "Chat")
        case .unavailable:
            String(localized: "Voice input isn't available on this iPhone right now. Check that Siri & Dictation is on, or type it instead.", table: "Chat")
        case .noMicrophone:
            String(localized: "Moonee can't find a microphone. Check that no other app is using it.", table: "Chat")
        case .failed:
            String(localized: "Moonee couldn't catch that. Hold the mic and try again?", table: "Chat")
        }
    }

    /// Said once when dictation runs in another language (Lao → Thai: Speech has no Lao).
    static func voiceFallback(_ locale: Locale) -> String {
        let name = Locale.current.localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "") ?? locale.identifier
        return String(localized: "Voice input doesn't support your language yet, so Moonee listens in \(name). You can always type instead.", table: "Chat")
    }

    static func heardNothing(variant: Int? = nil) -> String {
        pick([String(localized: "Moonee didn't hear anything. Hold the mic while you talk, then let go.", table: "Chat"),
              String(localized: "That was quiet! Tap the mic, say it, then tap again to send.", table: "Chat")], variant)
    }
}
