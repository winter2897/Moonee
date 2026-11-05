import Foundation
import SwiftData
import Testing
@testable import Moonee

@MainActor
struct CustomSkillsTests {
    let context = ModelContext(try! ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))

    static let taxFile = """
        ---
        name: Thuế thu nhập
        description: Hỏi đáp thuế TNCN
        triggers: thuế, quyết toán, tax
        tools:
          - spendingSummary
          - listTransactions
        ---
        Bạn giúp người dùng hiểu thuế thu nhập cá nhân.
        <!-- short -->
        Giải thích thuế TNCN ngắn gọn.
        """

    @Test func parsesTheFormat() throws {
        let d = try SkillFile.parse(Self.taxFile)
        #expect(d.name == "Thuế thu nhập")
        #expect(d.summary == "Hỏi đáp thuế TNCN")
        #expect(d.triggers == ["thuế", "quyết toán", "tax"])
        #expect(d.tools == ["spendingSummary", "listTransactions"])
        #expect(d.instructions == "Bạn giúp người dùng hiểu thuế thu nhập cá nhân.")
        #expect(d.shortInstructions == "Giải thích thuế TNCN ngắn gọn.")
        #expect(try SkillFile.parse("---\nname: A\ntriggers: [x, \"y\"]\n---\nDo it").triggers == ["x", "y"])
    }

    @Test(arguments: [
        ("no front matter", "Just text", SkillError.noFrontMatter),
        ("no name", "---\ntriggers: a\n---\nDo it", .missingName),
        ("no triggers", "---\nname: A\n---\nDo it", .noTriggers),
        ("no body", "---\nname: A\ntriggers: a\n---\n", .noInstructions),
        ("unknown tool", "---\nname: A\ntriggers: a\ntools: spendingSummary, deleteEverything\n---\nDo it", .unknownTools(["deleteEverything"])),
        ("api key", "---\nname: A\ntriggers: a\n---\nUse sk-or-v1-abcdef0123456789abcdef to call the API", .containsSecret),
        ("password", "---\nname: A\ntriggers: a\n---\nMy bank password: hunter2hunter2", .containsSecret),
        ("google key", "---\nname: A\ntriggers: a\n---\nAIzaSyA1234567890abcdefghijklmnopqrstuv", .containsSecret),
        ("too large", "---\nname: A\ntriggers: a\n---\n" + String(repeating: "x", count: 20_001), .tooLarge),
    ])
    func rejectsBadFiles(_ name: String, file: String, error: SkillError) {
        #expect(throws: error, "\(name)") { try SkillFile.parse(file) }
    }

    @Test func importsAndKeepsKeysUnique() throws {
        let a = try SkillStore.importFile(Self.taxFile, into: context)
        let b = try SkillStore.importFile(Self.taxFile, into: context)
        #expect(a.key == "user.thue-thu-nhap")
        #expect(b.key == "user.thue-thu-nhap-2")
        #expect(a.enabled)
        #expect(a.skill.tools == ["spendingSummary", "listTransactions"])
        #expect(throws: SkillError.containsSecret) { try a.update(SkillDraft(name: "A", triggers: ["a"], instructions: "token = abcdefgh12345")) }
        #expect(a.instructions == "Bạn giúp người dùng hiểu thuế thu nhập cá nhân.") // unchanged after the rejected edit
    }

    @Test func overrideAndResetBuiltIn() throws {
        try SkillStore.override(.jarBudgeting, text: SkillText(full: "Luôn trả lời bằng thơ lục bát."), language: "vi", in: context)
        #expect(SkillCatalog(context, language: "vi").resolved(.jarBudgeting).instructions(language: "vi", short: false) == "Luôn trả lời bằng thơ lục bát.")
        #expect(SkillCatalog(context, language: "en").resolved(.jarBudgeting).text == nil) // overrides are per language
        #expect(throws: SkillError.containsSecret) {
            try SkillStore.override(.jarBudgeting, text: SkillText(full: "key sk-ant-api03-abcdefghijklmnop"), language: "vi", in: context)
        }
        SkillStore.resetToDefault(Skill.jarBudgeting.id, language: "vi", in: context)
        let reset = SkillCatalog(context, language: "vi").resolved(.jarBudgeting)
        #expect(reset.text == nil)
        #expect(reset.instructions(language: "vi", short: false) == Skill.bundled("jar-budgeting", language: "vi").full)
    }

    @Test func routesToUserSkills() throws {
        let tax = try SkillStore.importFile(Self.taxFile, into: context)
        let catalog = SkillCatalog(context, language: "vi")
        #expect(Skill.route("Năm nay mình phải đóng thuế bao nhiêu?", context: Books.context, catalog: catalog).id == tax.key)
        #expect(Skill.route("tax refund rules?", context: Books.context, catalog: catalog).id == tax.key)
        #expect(Skill.route("đóng thuế 2tr", context: Books.context, catalog: catalog).id == "transaction-parser") // still a transaction
        #expect(Skill.route("chốt sổ tháng này", context: Books.context, catalog: catalog).id == "close-management")

        tax.enabled = false
        #expect(Skill.route("Năm nay mình phải đóng thuế bao nhiêu?", context: Books.context, catalog: SkillCatalog(context, language: "vi")).id
            == "spending-coach")
    }

    @Test func assistantUsesUserTextAndTools() async throws {
        try SkillStore.importFile(Self.taxFile, into: context)
        try SkillStore.override(.transactionParser, text: SkillText(full: "PARSER OVERRIDE"), language: "vi", in: context)
        let model = ScriptedLLM(replies: ["Thuế nè.", #"{"transactions":[{"amountText":"45k","kind":"expense","note":"Phở"}]}"#])
        var a = Assistant(router: AIRouter(mode: .byok, onDevice: nil, local: nil, cloud: model), tools: Books.tools, language: "vi")
        a.catalog = SkillCatalog(context, language: "vi")

        #expect(await a.handle("thuế năm nay thế nào?", context: Books.context) == .answer("Thuế nè.", skill: "user.thue-thu-nhap"))
        #expect(model.requests[0].system.contains("Bạn giúp người dùng hiểu thuế thu nhập cá nhân."))
        #expect(model.requests[0].tools.map(\.name) == ["spendingSummary", "listTransactions"])

        _ = await a.handle("phở 45k", context: Books.context)
        #expect(model.requests[1].system.contains("PARSER OVERRIDE"))
    }

    @Test func storeIsInTheSchema() {
        #expect(Schema.mooneeModels.contains { $0 == SkillStore.self })
    }
}
