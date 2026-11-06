import Foundation
import Testing
@testable import Moonee

struct LocalModelsTests {
    static let gib: UInt64 = 1 << 30

    // MARK: Catalog (spec §9.2)

    @Test func catalogEntriesArePinnedAndComplete() {
        #expect(Set(LocalModel.catalog.map(\.id)).count == LocalModel.catalog.count)
        for m in LocalModel.catalog {
            #expect(m.revision.count == 40 && m.revision.allSatisfy(\.isHexDigit), "pin a checked commit")
            #expect(["config.json", "model.safetensors", "tokenizer.json", "chat_template.jinja"].allSatisfy(m.files.contains))
            #expect(m.files.last == "model.safetensors", "weights last: the small files fail fast")
            #expect(m.downloadBytes > 0 && m.ramBytes > m.downloadBytes)
            #expect(m.url("config.json").absoluteString == "https://huggingface.co/\(m.repo)/resolve/\(m.revision)/config.json")
        }
        // Every family is listed and every model belongs to one.
        #expect(Set(LocalModel.catalog.map(\.family)) == Set(LocalModelFamily.all))
        #expect(LocalModelFamily.qwen.models.map(\.variant) == ["0.8B", "2B", "4B"])
        #expect(LocalModelFamily.all.allSatisfy { !$0.licence.isEmpty })
    }

    /// The ids downloads and the chosen model are stored under: renaming one would orphan a download.
    @Test func earlierIdsKeepWorking() {
        #expect(LocalModel.find("qwen3.5-0.8b") == .qwen08)
        #expect(LocalModel.find("qwen3.5-2b") == .qwen2)
        #expect(LocalModel.find("gemma4-e2b") == .gemmaE2B)
    }

    static func phone(limitGB: Double) -> DeviceMemory {
        DeviceMemory(physical: Int64(limitGB * 2e9), appLimit: Int64(limitGB * 1e9))
    }

    /// Recommended = best of the evaluated models that is not heavy for the phone (speed counts).
    @Test(arguments: [
        (1.5, nil),                // nothing runs comfortably
        (3.0, "qwen3.5-0.8b"),
        (5.0, "qwen3.5-2b"),
        (9.0, "gemma4-e2b"),
    ] as [(Double, String?)])
    func recommendsByAppMemoryLimit(limitGB: Double, expected: String?) {
        #expect(LocalModel.recommended(on: Self.phone(limitGB: limitGB))?.id == expected)
    }

    @Test func modelsThePhoneCannotHoldAreHidden() {
        let small = Self.phone(limitGB: 3)
        let runnable = LocalModel.runnable(on: small)
        #expect(runnable.contains(.qwen08) && runnable.contains(.lfm350m))
        #expect(!runnable.contains(.gemmaE2B) && !runnable.contains(.lfm8bA1B))
        #expect(runnable.allSatisfy { $0.ramBytes <= small.usable })
        #expect(LocalModel.runnable(on: DeviceMemory(physical: 16_000_000_000, appLimit: 12_000_000_000, gpuSupported: false)).isEmpty,
                "chips MLX cannot use get nothing")
    }

    @Test func heavyModelsAreFlagged() {
        let phone = Self.phone(limitGB: 6)
        #expect(LocalModel.qwen4.runs(on: phone) && LocalModel.qwen4.isHeavy(on: phone))
        #expect(!LocalModel.qwen2.isHeavy(on: phone))
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
