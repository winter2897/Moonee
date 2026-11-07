import Foundation

/// English parse dictionary: "45k", "3 grand", "$12", "yesterday", "last monday", "lent Tom 50".
extension Lexicon {
    static let en = Lexicon(
        language: "en",
        multipliers: [
            "k": 1_000, "grand": 1_000, "thousand": 1_000,
            "m": 1_000_000, "mil": 1_000_000, "million": 1_000_000, "bn": 1_000_000_000, "billion": 1_000_000_000,
        ],
        currencies: [
            "$": "USD", "usd": "USD", "dollar": "USD", "dollars": "USD", "buck": "USD", "bucks": "USD",
            "€": "EUR", "eur": "EUR", "euro": "EUR", "euros": "EUR", "£": "GBP", "gbp": "GBP", "¥": "JPY", "jpy": "JPY",
        ],
        dayOffsets: [
            "today": 0, "tonight": 0, "this morning": 0, "this afternoon": 0, "this evening": 0,
            "yesterday": -1, "last night": -1, "day before yesterday": -2, "the day before yesterday": -2, "last week": -7,
        ],
        // ponytail: full names only — "mon"/"sat" clash with Vietnamese words ("món").
        weekdays: ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7],
        lastWeekSuffixes: ["last week"],
        lastPrefixes: ["last"],
        kindPatterns: [
            (.transfer, "pay off * card"), (.transfer, "paid off * card"), (.transfer, "card payment"),
            (.transfer, "transfer|transferred|move|moved * to|from|into"), (.transfer, "withdraw|withdrew"),
            (.transfer, "top up"), (.transfer, "topped up"),
            (.borrow, "* lent|loaned me"), (.borrow, "borrow|borrowed * from *"),
            (.lend, "lent|lend|loaned * to *"), (.lend, "lent|lend|loaned *"),
            (.borrow, "borrow|borrowed"),
            (.repay, "* paid|pays me back"), (.repay, "paid|pay * back"), (.repay, "paid back *"), (.repay, "repaid|repay *"),
            (.income, "salary"), (.income, "paycheck"), (.income, "bonus"), (.income, "received"), (.income, "got paid"),
            (.income, "income"), (.income, "refund"), (.income, "dividend"), (.income, "interest"), (.income, "sold"), (.income, "earned"),
        ],
        notPerson: ["money", "me", "back", "cash", "card", "jar"],
        honorifics: ["mr", "mrs", "ms", "dr", "uncle", "aunt", "auntie"],
        toMarkers: ["to", "into"],
        separators: ["and", "then", "plus"],
        categories: [
            ("category.food", ["lunch", "dinner", "breakfast", "coffee", "cafe", "food", "groceries", "restaurant", "pizza", "burger", "drinks", "beer", "snack"]),
            ("category.transport", ["uber", "taxi", "gas", "fuel", "parking", "bus", "train", "flight", "metro", "subway"]),
            ("category.housing", ["rent", "electricity", "electric bill", "water bill", "internet", "utilities"]),
            ("category.shopping", ["amazon", "clothes", "shoes", "shopping", "supermarket"]),
            ("category.entertainment", ["movie", "movies", "cinema", "netflix", "spotify", "game", "concert"]),
            ("category.health", ["medicine", "doctor", "pharmacy", "gym", "dentist", "hospital"]),
            ("category.education", ["book", "books", "tuition", "course"]),
            ("category.charity", ["charity", "donation", "donate"]),
            ("category.salary", ["salary", "paycheck"]),
            ("category.bonus", ["bonus"]),
        ],
        bills: [ // specific first: "học phí nhà trường" is tuition
            ("category.entertainment", ["netflix", "spotify", "youtube", "icloud", "subscription"]),
            ("category.education", ["tuition", "school"]),
            ("category.health", ["insurance", "gym"]),
            ("category.transport", ["parking", "fuel"]),
            ("category.housing", ["rent", "electricity", "electric", "power", "water", "gas", "internet", "wifi", "phone", "mobile",
                                  "utilities", "hoa"]),
        ],
        jars: [
            ("jar.essentials", ["essentials", "necessities"]), ("jar.investing", ["investment", "investing", "financial freedom"]),
            ("jar.savings", ["savings", "saving"]), ("jar.growth", ["education", "self-development", "growth"]),
            ("jar.play", ["play", "fun"]), ("jar.giving", ["giving"]),
        ],
        jarWords: ["jar"],
        limitWords: ["limit", "spending limit"],
        questionCues: ["how much", "how many", "what", "why", "should i", "how do", "how can", "can i", "tips", "advice"],
        skillCues: [
            ("close-management", ["close the month", "month end", "month-end", "monthly report", "wrap up the month"]),
            ("jar-budgeting", ["split my income", "split my salary", "split income", "rebalance", "allocate"]),
            ("debt-tracking", ["owe", "owes", "owe me", "debt", "debts", "debt book", "lent", "borrowed", "pay me back"]),
            ("market-lookup", ["gold price", "price of gold", "exchange rate", "interest rate", "stock price", "share price",
                               "bitcoin", "btc", "ethereum", "eth", "crypto", "news", "gas price", "search the web", "look up"]),
        ],
        periods: [
            "today": "today", "this week": "thisWeek", "last week": "lastWeek", "this month": "thisMonth",
            "last month": "lastMonth", "this year": "thisYear", "last year": "lastYear",
        ],
        receiptTotals: ["amount due", "grand total", "total due", "balance due", "total"]
    )
}
