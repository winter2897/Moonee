import Foundation
import Testing
@testable import Moonee

struct ToolsTests {
    let tools = Books.tools

    @Test func spendingSummary() async throws {
        let s = try #require(await tools.json("spendingSummary", #"{"period":"thisMonth"}"#) as? [String: Any])
        #expect(s["spent"] as? String == "₫3,400,000")
        #expect(s["previousSpent"] as? String == "₫4,400,000")
        #expect(s["change"] as? String == "-23%")
        #expect(s["income"] as? String == "₫10,000,000")
        #expect(s["transactionCount"] as? Int == 3)
        #expect(s["from"] as? String == "2026-11-01")
        #expect(s["to"] as? String == "2026-11-30")
        let top = try #require(s["topCategories"] as? [[String: String]])
        #expect(top.first == ["name": "Ăn uống", "spent": "₫2,500,000", "share": "74%"])

        let food = try #require(await tools.json("spendingSummary", #"{"period":"thisMonth","categoryKey":"category.food"}"#) as? [String: Any])
        #expect(food["spent"] as? String == "₫2,500,000")
        #expect(food["change"] as? String == "-17%")

        let last = try #require(await tools.json("spendingSummary", #"{"period":"lastMonth","jarKey":"jar.play"}"#) as? [String: Any])
        #expect(last["spent"] as? String == "₫1,200,000")
    }

    @Test func listTransactions() async throws {
        let rows = try #require(await tools.json("listTransactions", #"{"limit":2}"#) as? [[String: Any]])
        #expect(rows.map { $0["kind"] as? String } == ["jarTransfer", "lend"])
        #expect(rows[1]["person"] as? String == "Nam")
        let spending = try #require(await tools.json("listTransactions", #"{"kind":"expense"}"#) as? [[String: Any]])
        #expect(spending.map { $0["amount"] as? String } == ["₫900,000", "₫500,000", "₫2,000,000"])
    }

    @Test func jarBalances() async throws {
        let jars = try #require(await tools.json("jarBalances") as? [[String: Any]])
        let play = try #require(jars.first { $0["key"] as? String == "jar.play" })
        #expect(play["balance"] as? String == "₫200,000")
        #expect(play["fundedThisMonth"] as? String == "₫1,300,000") // salary share + jar transfer in
        #expect(play["spentThisMonth"] as? String == "₫900,000")
        #expect(play["usedThisMonth"] as? String == "82%")              // 900k / (−200k opening + 1.3tr)
        #expect(play["status"] as? String == "warning")
        let essentials = try #require(jars.first { $0["key"] as? String == "jar.essentials" })
        #expect(essentials["usedThisMonth"] as? String == "32%")
        #expect(essentials["status"] as? String == "ok")
    }

    @Test func splitIncome() async throws {
        let s = try #require(await tools.json("splitIncome", #"{"amountText":"15tr"}"#) as? [String: Any])
        #expect(s["amount"] as? String == "₫15,000,000")
        let jars = try #require(s["jars"] as? [[String: String]])
        #expect(jars.map { $0["amount"] } == ["₫8,250,000", "₫1,500,000", "₫1,500,000", "₫1,500,000", "₫1,500,000", "₫750,000"])
        // Rounding leftovers go to the biggest jar so the split always adds up.
        let odd = try #require(await tools.json("splitIncome", #"{"amountText":"1000001"}"#) as? [String: Any])
        #expect((odd["jars"] as? [[String: String]])?.first?["amount"] == "₫550,001")
    }

    @Test func savingsPlan() async throws {
        // "Laptop 30tr trước Tết" (Tết 2027 = 6 Feb): 78 days → 12 weeks, 3 months.
        let p = try #require(await tools.json("savingsPlan", #"{"targetText":"laptop 30tr","deadline":"2027-02-06"}"#) as? [String: Any])
        #expect(p["daysLeft"] as? Int == 78)
        #expect(p["perWeek"] as? String == "₫2,500,000")
        #expect(p["perMonth"] as? String == "₫10,000,000")
        let saved = try #require(await tools.json("savingsPlan", #"{"targetText":"30tr","savedText":"6 củ","deadline":"2027-02-06"}"#) as? [String: Any])
        #expect(saved["remaining"] as? String == "₫24,000,000")
        #expect(saved["perWeek"] as? String == "₫2,000,000")
        // Bad input becomes an error the model can read, never a crash.
        let past = try #require(await tools.json("savingsPlan", #"{"targetText":"30tr","deadline":"2026-01-01"}"#) as? [String: Any])
        #expect(past["error"] != nil)
    }

    @Test func monthClose() async throws {
        let c = try #require(await tools.json("monthClose", #"{"month":"lastMonth"}"#) as? [String: Any])
        #expect(c["income"] as? String == "₫10,000,000")
        #expect(c["spent"] as? String == "₫4,400,000")
        #expect(c["saved"] as? String == "₫5,600,000")
        #expect(c["savingsRate"] as? String == "+56%")
        #expect(c["uncategorizedCount"] as? Int == 1)
        #expect(c["negativeJars"] as? [String] == ["Hưởng thụ"])
        // Moonee's order: Play is the one below zero, so Growth gives first; Essentials never does.
        #expect(c["suggestedMoves"] as? [[String: String]] == [["from": "Phát triển bản thân", "to": "Hưởng thụ", "amount": "₫200,000"]])
        let jars = try #require(c["jars"] as? [[String: String]])
        #expect(jars.first { $0["name"] == "Hưởng thụ" }?["closing"] == "-₫200,000")
        #expect(jars.first { $0["name"] == "Thiết yếu" }?["closing"] == "₫2,300,000")
    }

    @Test func toolErrorsAreJSON() async {
        let unknown = await tools.all.call("nope", arguments: Data())
        #expect(unknown.contains("unknown tool"))
        let badArgs = await tools.json("spendingSummary", #"{"period":"someday"}"#) as? [String: Any]
        #expect(badArgs?["error"] != nil)
    }

    @Test func everyToolWorksWithFoundationModels() throws {
        for tool in tools.all { _ = try FoundationTool(tool) } // schema converts to a GenerationSchema
        #expect(Set(Skill.all.flatMap(\.tools)).isSubset(of: Set(tools.all.map(\.name))))
    }
}
