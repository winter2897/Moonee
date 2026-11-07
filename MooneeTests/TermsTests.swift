import Foundation
import Testing
@testable import Moonee

struct TermsTests {
    static let languages = ["en", "vi", "th", "lo"]

    @Test func consentGating() throws {
        let defaults = try #require(UserDefaults(suiteName: "TermsTests"))
        defaults.removePersistentDomain(forName: "TermsTests")
        let accepted = { defaults.integer(forKey: Prefs.termsVersion) }

        #expect(Terms.needsConsent(accepted: accepted())) // fresh install: never accepted
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        Terms.accept(defaults, now: now)
        #expect(accepted() == Terms.version)
        #expect(defaults.object(forKey: Prefs.termsAcceptedAt) as? Date == now)
        #expect(!Terms.needsConsent(accepted: accepted()))
        // The terms version rose since: asked again.
        #expect(Terms.needsConsent(accepted: Terms.version - 1))
    }

    @Test func termsShipInEveryLanguageAndMatchTheDoc() throws {
        let doc = try String(contentsOf: LocalizationCoverageTests.sources.deletingLastPathComponent().appending(path: "docs/TERMS.md"), encoding: .utf8)
        for lang in Self.languages {
            let text = Skill.resource("terms", language: lang)
            #expect(text.contains("\(Terms.version)"), "terms.\(lang).md")
            #expect(text.split(separator: "\n").filter { $0.hasPrefix("## ") }.count == 9, "terms.\(lang).md: 9 sections")
            if ["en", "vi"].contains(lang) { #expect(doc.contains(text), "docs/TERMS.md differs from terms.\(lang).md") }
        }
    }

    /// Every language, full and small-model parts: no buy/sell/hold advice, no price predictions, point to a licensed adviser.
    @Test func aiFilesCarryTheNoInvestmentAdviceRule() {
        let licensed = ["en": "licensed adviser", "vi": "có giấy phép", "th": "ใบอนุญาต", "lo": "ໃບອະນຸຍາດ"]
        let predict = ["en": "predict prices", "vi": "dự đoán giá", "th": "ทำนายราคา", "lo": "ທຳນາຍລາຄາ"]
        for lang in Self.languages {
            for name in ["moonee", "market-lookup", "jar-budgeting"] {
                let parts = Skill.resource("\(name)", language: lang).components(separatedBy: "<!-- short -->")
                #expect(parts.count == 2, "\(name).\(lang).md")
                for (i, part) in parts.enumerated() {
                    let where_ = "\(name).\(lang).md \(i == 0 ? "full" : "short")"
                    #expect(part.contains(licensed[lang]!), "\(where_): licensed adviser")
                    #expect(part.contains(predict[lang]!), "\(where_): no price predictions")
                }
            }
        }
    }

    @Test func footerOnlyOnMarketAndInvestingAnswers() {
        #expect(Terms.needsFooter(skill: Skill.marketLookup.id, question: "giá vàng hôm nay"))
        #expect(Terms.needsFooter(skill: Skill.spendingCoach.id, question: "Có nên đầu tư cổ phiếu không?"))
        #expect(Terms.needsFooter(skill: Skill.jarBudgeting.id, question: "Should I buy gold now?"))
        #expect(Terms.needsFooter(skill: Skill.spendingCoach.id, question: "ควรซื้อหุ้นไหม"))
        #expect(!Terms.needsFooter(skill: Skill.spendingCoach.id, question: "Tháng này mình tiêu bao nhiêu?"))
        #expect(!Terms.needsFooter(skill: Skill.jarBudgeting.id, question: "How much is left for fun?"))
        #expect(!Terms.needsFooter(skill: Skill.closeManagement.id, question: "close the month"))
    }
}
