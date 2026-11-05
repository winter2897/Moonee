import Foundation
import MLXLMCommon

// Vietnamese parse eval (spec §9.2): the spec's examples + everyday phrases, run through
// QuickParser (rules), Assistant.parse with Apple on-device, and Assistant.parse with each local model.
// A phrase passes when every expected transaction comes out with the right amount, kind, category
// (any of the accepted keys) and wallet / jar / person when given, and nothing extra.

struct Expect {
    var amount: Int
    var kind: EntryKind
    var categories: Set<String> = []
    var wallet: String?
    var toWallet: String?
    var jar: String?
    var toJar: String?
    var person: String?

    func matches(_ t: ParsedTxn) -> Bool {
        t.amount == amount && t.kind == kind
            && (categories.isEmpty || categories.contains(t.categoryKey ?? ""))
            && (wallet == nil || t.wallet == wallet) && (toWallet == nil || t.toWallet == toWallet)
            && (jar == nil || t.jar == jar) && (toJar == nil || t.toJar == toJar)
            && (person == nil || (t.person ?? "").localizedCaseInsensitiveContains(person!))
    }
}

func exp(_ amount: Int, _ cats: String...) -> Expect {
    Expect(amount: amount, kind: .expense, categories: Set(cats.map { "category." + $0 }))
}

let phrases: [(String, [Expect])] = [
    // Spec §3.1 examples
    ("phở 45k, cafe 29k, grab 32k", [exp(45_000, "food"), exp(29_000, "food"), exp(32_000, "transport")]),
    ("cà phê 30k", [exp(30_000, "food")]),
    ("ăn trưa 1 củ", [exp(1_000_000, "food")]),
    ("nhậu 2 lít", [exp(200_000, "food", "entertainment")]),
    ("ăn tối 1tr2 hôm qua", [exp(1_200_000, "food")]),
    ("đổ xăng 50k sáng nay", [exp(50_000, "transport")]),
    ("grab 32k thứ 2 tuần trước", [exp(32_000, "transport")]),
    // Everyday phrases: all 7 kinds, merchants with no keyword, several per message
    ("lương tháng 11 15 triệu", [Expect(amount: 15_000_000, kind: .income, categories: ["category.salary"])]),
    ("thưởng tết 5tr", [Expect(amount: 5_000_000, kind: .income, categories: ["category.bonus"])]),
    ("bán đồ cũ được 300k", [Expect(amount: 300_000, kind: .income, categories: ["category.otherIncome"])]),
    ("cho anh Tuấn mượn 2tr", [Expect(amount: 2_000_000, kind: .lend, person: "Tuấn")]),
    ("vay mẹ 3 triệu", [Expect(amount: 3_000_000, kind: .borrow, person: "mẹ")]),
    ("trả nợ chị Lan 500k", [Expect(amount: 500_000, kind: .repay, person: "Lan")]),
    ("chuyển 1tr từ Vietcombank sang MoMo", [Expect(amount: 1_000_000, kind: .transfer, wallet: "Vietcombank", toWallet: "MoMo")]),
    ("chuyển 300k từ lọ tiết kiệm sang lọ hưởng thụ", [Expect(amount: 300_000, kind: .jarTransfer, jar: "jar.savings", toJar: "jar.play")]),
    ("tiền điện tháng này 650k", [exp(650_000, "housing")]),
    ("tiền nhà 4tr5", [exp(4_500_000, "housing")]),
    ("mua thuốc cảm 120k", [exp(120_000, "health")]),
    ("đóng học phí tiếng Anh 2tr5", [exp(2_500_000, "education")]),
    ("mua áo khoác trên shopee 450k", [exp(450_000, "shopping")]),
    ("xem phim với bạn 180k", [exp(180_000, "entertainment")]),
    ("ủng hộ quỹ từ thiện 200k", [exp(200_000, "charity")]),
    ("highlands 59k", [exp(59_000, "food")]),
    ("be bike về nhà 25k", [exp(25_000, "transport")]),
    ("sửa xe máy 350k", [exp(350_000, "transport", "other")]),
    ("mua quà sinh nhật cho mẹ 800k", [exp(800_000, "shopping", "other")]),
    ("trà sữa 35k với bánh mì 20k", [exp(35_000, "food"), exp(20_000, "food")]),
    ("đi siêu thị 1,2 triệu bằng thẻ Vietcombank",
     [Expect(amount: 1_200_000, kind: .expense, categories: ["category.food", "category.shopping"], wallet: "Vietcombank")]),
]

func passes(_ got: [ParsedTxn], _ want: [Expect]) -> Bool {
    guard got.count == want.count else { return false }
    var left = got
    for e in want {
        guard let i = left.firstIndex(where: e.matches) else { return false }
        left.remove(at: i)
    }
    return true
}

struct EmptyLedger: LedgerReading {
    var currency = "VND"
    func jars() async throws -> [LedgerJar] { [] }
    func transactions(in _: DateInterval) async throws -> [LedgerTxn] { [] }
}

var context = ParserContext()
context.currency = "VND"
context.calendar = Calendar(identifier: .gregorian)
context.dayFirst = true
context.wallets = ["Tiền mặt", "Vietcombank", "MoMo"]

/// Forwards to a model and prints what it returned or threw, so rejected outputs can be explained.
struct Recording: LLM {
    let inner: any LLM
    var isSmall: Bool { inner.isSmall }
    func respond(_ r: LLMRequest) async throws -> String { try await inner.respond(r) }
    func extractTransactions(instructions: String, text: String) async throws -> [AIParsedTxn] {
        do {
            let items = try await inner.extractTransactions(instructions: instructions, text: text)
            print("   raw:", items.map { "\($0.amountText ?? "nil")|\($0.kind)|\($0.category ?? "nil")|\($0.dateText ?? "nil")" }.joined(separator: " ; "))
            return items
        } catch {
            print("   threw:", String(describing: error).prefix(300))
            throw error
        }
    }
}

func assistant(_ router: AIRouter) -> Assistant {
    Assistant(router: router, tools: MooneeTools(ledger: EmptyLedger()), language: "vi")
}

struct EvalRow { var engine: String; var pass = 0; var modelOutputs = 0; var modelPass = 0; var ms: [Double] = []; var failures: [String] = [] }

func run(_ engine: String, _ parse: (String) async -> ([ParsedTxn], Bool)) async -> EvalRow {
    var row = EvalRow(engine: engine)
    for (text, want) in phrases {
        let t0 = ContinuousClock.now
        let (got, usedModel) = await parse(text)
        let d = ContinuousClock.now - t0
        row.ms.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        let ok = passes(got, want)
        if ok { row.pass += 1 } else {
            row.failures.append("\(text) → " + got.map { "\($0.amount ?? -1) \($0.kind.rawValue) \($0.categoryKey ?? "-") \($0.person ?? $0.toWallet ?? $0.toJar ?? "")" }.joined(separator: "; ") + (usedModel ? "" : " [rules]"))
        }
        if usedModel { row.modelOutputs += 1; if ok { row.modelPass += 1 } }
        print(ok ? "✓" : "✗", engine, text, String(format: "%.0f ms", row.ms.last!))
    }
    return row
}

func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

precondition(!Skill.transactionParser.instructions(language: "vi", short: true).isEmpty,
             "skill files not found next to the binary: use run.sh")

var rows: [EvalRow] = []
rows.append(await run("QuickParser (rules)") { (QuickParser.parse($0, context: context), false) })

if AppleLLM.isAvailable {
    let a = assistant(AIRouter(mode: .onDevice, onDevice: Recording(inner: AppleLLM()), local: nil, cloud: nil))
    rows.append(await run("Apple on-device") { await a.parse($0, context: context) })
} else {
    print("Apple on-device: unavailable (\(LLMSettings.appleStatus))")
}

let store = LocalModelStore(root: URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/models"))
let downloads = LocalModelDownloads(store: store)
var speeds: [String: (load: Double, tps: Double)] = [:]
for m in LocalModel.catalog {
    if downloads.state(m) != .downloaded {
        print("Downloading \(m.name) (\(m.downloadBytes.formatted(.byteCount(style: .file))))…")
        downloads.start(m)
        while true {
            switch downloads.state(m) {
            case .downloaded: break
            case .failed(let e): fatalError("\(m.name): \(e)")
            default: try await Task.sleep(for: .seconds(2)); continue
            }
            break
        }
    }
    let local = LocalLLM(model: m, folder: store.folder(m))
    let t0 = ContinuousClock.now
    let container = try await LocalRuntime.shared.container(local.folder)
    let load = ContinuousClock.now - t0
    // Decode speed on a short Vietnamese answer.
    var tps = 0.0
    let session = ChatSession(container, generateParameters: GenerateParameters(maxTokens: 120, temperature: 0),
                              additionalContext: ["enable_thinking": false])
    for try await g in session.streamDetails(to: "Giải thích ngắn gọn cách chia thu nhập vào 6 lọ.", images: [], videos: []) {
        if case .info(let info) = g { tps = info.tokensPerSecond }
    }
    speeds[m.name] = (Double(load.components.seconds) + Double(load.components.attoseconds) / 1e18, tps)
    let a = assistant(AIRouter(mode: .local, onDevice: nil, local: Recording(inner: local), cloud: nil))
    rows.append(await run(m.name) { await a.parse($0, context: context) })
    await LocalRuntime.shared.unload()
}

print("\n| Engine | Correct (of \(phrases.count)) | Model output accepted | Correct when model answered | Median latency |")
print("|---|---|---|---|---|")
for r in rows {
    let model = r.engine.hasPrefix("QuickParser") ? "–" : "\(r.modelOutputs)/\(phrases.count)"
    let modelPass = r.engine.hasPrefix("QuickParser") ? "–" : "\(r.modelPass)/\(r.modelOutputs)"
    print("| \(r.engine) | \(r.pass) (\(r.pass * 100 / phrases.count)%) | \(model) | \(modelPass) | \(Int(median(r.ms))) ms |")
}
print("\n| Model | Load (warm disk) | Decode tokens/s |")
print("|---|---|---|")
for m in LocalModel.catalog { if let s = speeds[m.name] { print("| \(m.name) | \(String(format: "%.1f", s.load)) s | \(Int(s.tps)) |") } }
print("\nFailures:")
for r in rows { for f in r.failures { print("- \(r.engine): \(f)") } }
