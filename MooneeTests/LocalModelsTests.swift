import Foundation
import Testing
@testable import Moonee

struct LocalModelsTests {
    static let gib: UInt64 = 1 << 30

    // MARK: Catalog (spec §9.2)

    @Test func catalogEntriesArePinnedAndComplete() {
        #expect(Set(LocalModel.catalog.map(\.id)).count == LocalModel.catalog.count)
        for m in LocalModel.catalog {
            #expect(m.revision.count == 40 && m.revision.allSatisfy(\.isHexDigit), "pin the evaluated commit")
            #expect(["config.json", "model.safetensors", "tokenizer.json", "chat_template.jinja"].allSatisfy(m.files.contains))
            #expect(m.downloadBytes > 0 && m.ramBytes > 0 && m.tokensPerSecond > 0)
            #expect(!m.licence.isEmpty)
            #expect(m.url("config.json").absoluteString == "https://huggingface.co/\(m.repo)/resolve/\(m.revision)/config.json")
        }
    }

    /// Phones report a bit less RAM than they are sold with.
    @Test(arguments: [
        (UInt64(3_700_000_000), nil),               // 4 GB iPhone: no local model
        (UInt64(5_900_000_000), "qwen3.5-0.8b"),    // 6 GB (iPhone 15)
        (UInt64(7_900_000_000), "qwen3.5-2b"),      // 8 GB (iPhone 15 Pro / 16 / 17)
        (UInt64(11_900_000_000), "gemma4-e2b"),     // 12 GB (iPhone 17 Pro)
    ] as [(UInt64, String?)])
    func recommendsByRAM(ram: UInt64, expected: String?) {
        #expect(LocalModel.recommended(physicalMemory: ram)?.id == expected)
    }

    @Test func bigModelsAreHiddenOnSmallPhones() {
        #expect(!LocalModel.gemmaE2B.fits(physicalMemory: 8 * Self.gib))
        #expect(LocalModel.gemmaE2B.fits(physicalMemory: 11 * Self.gib))
        #expect(LocalModel.qwen08.fits(physicalMemory: 6 * Self.gib))
    }

    // MARK: Download state on disk

    func tempStore() -> LocalModelStore {
        LocalModelStore(root: FileManager.default.temporaryDirectory.appending(path: "models-\(UUID().uuidString)"))
    }

    static func resumeData(received: Int64) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["NSURLSessionResumeBytesReceived": received], format: .binary, options: 0)
    }

    @Test func stateFollowsFilesOnDisk() throws {
        let store = tempStore(), m = LocalModel.qwen08
        defer { try? FileManager.default.removeItem(at: store.root) }
        #expect(store.state(m) == .notDownloaded)

        try store.prepareFolder(m)
        try Data(count: 1000).write(to: store.folder(m).appending(path: "config.json"))
        #expect(store.isFetched(m, "config.json"))
        #expect(!store.isFetched(m, "model.safetensors"))
        #expect(store.bytesOnDisk(m) == 1000)

        // An interrupted weights file counts what URLSession already received.
        try Self.resumeData(received: 64_000_000).write(to: store.resumeURL(m, "model.safetensors"))
        #expect(store.bytesOnDisk(m) == 64_001_000)
        #expect(store.state(m) == .paused(64_001_000 / Double(m.downloadBytes)))

        try store.markComplete(m)
        #expect(store.state(m) == .downloaded)

        store.delete(m)
        #expect(store.state(m) == .notDownloaded)
    }

    @Test func downloadsFolderIsNotBackedUp() throws {
        let store = tempStore(), m = LocalModel.qwen08
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.prepareFolder(m)
        #expect(try store.folder(m).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func resumeDataParsing() throws {
        #expect(LocalModelStore.receivedBytes(resumeData: nil) == 0)
        #expect(LocalModelStore.receivedBytes(resumeData: Data("junk".utf8)) == 0)
        #expect(LocalModelStore.receivedBytes(resumeData: try Self.resumeData(received: 42)) == 42)
    }

    @MainActor @Test func launchRestoresStatesFromDisk() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.prepareFolder(.qwen2)
        try store.markComplete(.qwen2)
        try store.prepareFolder(.qwen08)
        try Self.resumeData(received: 1_000).write(to: store.resumeURL(.qwen08, "model.safetensors"))

        let downloads = LocalModelDownloads(store: store)
        #expect(downloads.state(.qwen2) == .downloaded)
        #expect(downloads.state(.gemmaE2B) == .notDownloaded)
        guard case .paused(let f) = downloads.state(.qwen08) else { Issue.record("expected paused"); return }
        #expect(f > 0 && f < 0.001)
    }

    // MARK: Constrained JSON

    @Test func jsonSchemaMatchesTheGenerableShape() throws {
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(AIParsedTxn.jsonSchema.utf8)) as? [String: Any])
        let items = try #require(((schema["properties"] as? [String: Any])?["transactions"] as? [String: Any])?["items"] as? [String: Any])
        let props = try #require(items["properties"] as? [String: Any])
        let sample = AIParsedTxn(amountText: "45k", kind: "expense", category: "x", wallet: "x", toWallet: "x",
                                 jar: "x", toJar: "x", person: "x", dateText: "x", note: "x")
        let keys = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any]).keys
        #expect(Set(props.keys) == Set(keys))
        #expect(Set(items["required"] as? [String] ?? []) == Set(keys))
        #expect((props["kind"] as? [String: Any])?["enum"] as? [String] == EntryKind.allCases.map(\.rawValue))
    }

    @Test func simulatorHasNoLocalModel() {
        #if targetEnvironment(simulator)
        #expect(!LocalLLM.isSupported)
        #expect(LocalLLM.current == nil)
        #endif
    }
}
