import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(Metal)
import Metal
#endif

/// A maker's line of open models, as the models screen groups them (spec §9.2).
struct LocalModelFamily: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let maker: String
    /// Neutral SF Symbol (no brand logos).
    let symbol: String
    let summary: LocalizedStringResource
    /// Released in the last few months.
    let isNew: Bool
    let licence: String
    let licenceURL: URL

    static let qwen = LocalModelFamily(
        id: "qwen", name: "Qwen 3.5", maker: "Alibaba", symbol: "circle.hexagongrid",
        summary: LocalizedStringResource("All-rounders with hybrid thinking and wide language support, Vietnamese included.", table: "LocalModels"),
        isNew: false, licence: "Apache-2.0", licenceURL: URL(string: "https://huggingface.co/Qwen/Qwen3.5-2B/blob/main/LICENSE")!)
    static let gemma = LocalModelFamily(
        id: "gemma", name: "Gemma 4", maker: "Google", symbol: "diamond",
        summary: LocalizedStringResource("Google's open models made for phones. The best Vietnamese here, but heavier.", table: "LocalModels"),
        isNew: false, licence: "Apache-2.0", licenceURL: URL(string: "https://ai.google.dev/gemma/docs/gemma_4_license")!)
    static let lfm = LocalModelFamily(
        id: "lfm", name: "LFM 2.5", maker: "Liquid AI", symbol: "drop",
        summary: LocalizedStringResource("Very fast hybrid models built for phones. English first: Vietnamese is basic.", table: "LocalModels"),
        isNew: true, licence: "LFM Open License v1.0", licenceURL: URL(string: "https://www.liquid.ai/lfm-license")!)
    static let minicpm = LocalModelFamily(
        id: "minicpm", name: "MiniCPM 5", maker: "OpenBMB", symbol: "square.stack.3d.up",
        summary: LocalizedStringResource("Compact, efficient models. Chinese and English first: Vietnamese is basic.", table: "LocalModels"),
        isNew: true, licence: "Apache-2.0", licenceURL: URL(string: "https://huggingface.co/openbmb/MiniCPM5-2B-MLX")!)
    static let bonsai = LocalModelFamily(
        id: "bonsai", name: "Bonsai", maker: "PrismML", symbol: "leaf",
        summary: LocalizedStringResource("Ternary (2-bit) models: big-model answers in a small download. Vietnamese is basic.", table: "LocalModels"),
        isNew: false, licence: "Apache-2.0", licenceURL: URL(string: "https://huggingface.co/prism-ml/Ternary-Bonsai-8B-mlx-2bit")!)

    static let all = [qwen, gemma, lfm, minicpm, bonsai]

    var models: [LocalModel] { LocalModel.catalog.filter { $0.family == self } }

    static func == (a: LocalModelFamily, b: LocalModelFamily) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// An open model Moonee can download and run on the phone (spec §9.2). Weights come from Hugging Face on demand,
/// never bundled. Each entry pins a commit we checked loads with MLX Swift (MLXLLM).
/// ponytail: text-only. Vision variants (LFM2.5-VL) and vision towers are skipped, receipts are OCR'd first (spec §9.3);
/// add MLXVLM when photos should go straight to a model. Bonsai's 1-bit builds need PrismML's mlx-swift fork, so the
/// catalog has its ternary (2-bit) builds, which stock MLX runs.
struct LocalModel: Identifiable, Sendable, Hashable {
    enum Vietnamese: Sendable { case basic, good }

    let id: String
    let family: LocalModelFamily
    /// Size/flavour within the family: "2B", "1.2B Thinking".
    let variant: String
    /// MLX conversion on Hugging Face: 4-bit (Bonsai: ternary 2-bit).
    let repo: String
    let revision: String
    /// Sum of `files`.
    let downloadBytes: Int64
    let vietnamese: Vietnamese
    /// Can reason before answering (Moonee keeps it off; see `LocalLLM`).
    let thinking: Bool
    /// Weights, config, tokenizer, chat template; small files first. Vision/processor files are skipped.
    let files: [String]
    let note: LocalizedStringResource

    init(id: String, family: LocalModelFamily, variant: String, repo: String, revision: String, downloadBytes: Int64,
         vietnamese: Vietnamese, thinking: Bool, files: [String], note: String.LocalizationValue) {
        (self.id, self.family, self.variant, self.repo, self.revision, self.downloadBytes) = (id, family, variant, repo, revision, downloadBytes)
        (self.vietnamese, self.thinking, self.files) = (vietnamese, thinking, files)
        self.note = LocalizedStringResource(note, table: "LocalModels")
    }

    var name: String { "\(family.name) \(variant)" }

    /// Memory while answering: the weights plus KV cache, activations and the JSON grammar for a short chat.
    /// ponytail: flat 400 MB overhead, measured ~250–400 MB on the Mac; measure per model if a phone runs out.
    var ramBytes: Int64 { downloadBytes + 400_000_000 }

    static func == (a: LocalModel, b: LocalModel) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    static let qwen08 = LocalModel(
        id: "qwen3.5-0.8b", family: .qwen, variant: "0.8B", repo: "mlx-community/Qwen3.5-0.8B-4bit",
        revision: "da28692b5f139cb0ec58a356b437486b7dac7462", downloadBytes: 645_302_309, vietnamese: .basic, thinking: true,
        files: ["chat_template.jinja", "config.json", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"],
        note: "Smallest Qwen: quick replies, simple expense logging.")

    static let qwen2 = LocalModel(
        id: "qwen3.5-2b", family: .qwen, variant: "2B", repo: "mlx-community/Qwen3.5-2B-4bit",
        revision: "674aaa7240b91e8012fcad5d791b7dfe5ba90207", downloadBytes: 1_742_354_857, vietnamese: .good, thinking: true,
        files: ["chat_template.jinja", "config.json", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"],
        note: "The balanced pick: good Vietnamese at a quick pace.")

    static let qwen4 = LocalModel(
        id: "qwen3.5-4b", family: .qwen, variant: "4B", repo: "mlx-community/Qwen3.5-4B-4bit",
        revision: "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c", downloadBytes: 3_054_404_243, vietnamese: .good, thinking: true,
        files: ["chat_template.jinja", "config.json", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"],
        note: "Smarter answers, but slower and warmer.")

    static let gemmaE2B = LocalModel(
        id: "gemma4-e2b", family: .gemma, variant: "E2B", repo: "mlx-community/gemma-4-e2b-it-4bit",
        revision: "238767527555cb75a05732a84dff5d6ba0dd6809", downloadBytes: 3_583_085_182, vietnamese: .good, thinking: true,
        files: ["chat_template.jinja", "config.json", "generation_config.json", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"],
        note: "Best Vietnamese parsing in our tests.")

    static let gemmaE4B = LocalModel(
        id: "gemma4-e4b", family: .gemma, variant: "E4B", repo: "mlx-community/gemma-4-e4b-it-4bit",
        revision: "475b9088d29754a3379866cf5aeb6b41acd313c2", downloadBytes: 5_179_238_033, vietnamese: .good, thinking: true,
        files: ["chat_template.jinja", "config.json", "generation_config.json", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"],
        note: "Larger Gemma for phones with plenty of memory.")

    static let lfm230m = LocalModel(
        id: "lfm2.5-230m", family: .lfm, variant: "230M", repo: "LiquidAI/LFM2.5-230M-MLX-4bit",
        revision: "817c2706bbbf7a88f16346469b5747b950087e0e", downloadBytes: 150_853_221, vietnamese: .basic, thinking: false,
        files: ["chat_template.jinja", "config.json", "generation_config.json", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"],
        note: "Tiny and instant. English only in practice.")

    static let lfm350m = LocalModel(
        id: "lfm2.5-350m", family: .lfm, variant: "350M", repo: "LiquidAI/LFM2.5-350M-MLX-4bit",
        revision: "f6cb4e006bb7a2d8a6afa14ec0a53e0586f65a5b", downloadBytes: 226_571_069, vietnamese: .basic, thinking: false,
        files: ["chat_template.jinja", "config.json", "generation_config.json", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"],
        note: "Tiny and very fast, for short English answers.")

    static let lfm1_2 = LocalModel(
        id: "lfm2.5-1.2b", family: .lfm, variant: "1.2B Instruct", repo: "LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit",
        revision: "7ccafdb04c36936f4f1c4685198c6c9a40275932", downloadBytes: 663_393_252, vietnamese: .basic, thinking: false,
        files: ["chat_template.jinja", "config.json", "generation_config.json", "model.safetensors.index.json", "special_tokens_map.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"],
        note: "Fast general chat.")

    static let lfm1_2Thinking = LocalModel(
        id: "lfm2.5-1.2b-thinking", family: .lfm, variant: "1.2B Thinking", repo: "LiquidAI/LFM2.5-1.2B-Thinking-MLX-4bit",
        revision: "0703c92f46e0dfdfd4fe3c989b5f55615c6c3031", downloadBytes: 663_393_252, vietnamese: .basic, thinking: true,
        files: ["chat_template.jinja", "config.json", "generation_config.json", "model.safetensors.index.json", "special_tokens_map.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"],
        note: "Reasons step by step before it answers.")

    static let lfm2_6 = LocalModel(
        id: "lfm2.5-2.6b", family: .lfm, variant: "2.6B", repo: "LiquidAI/LFM2.5-2.6B-MLX-4bit",
        revision: "04efa23776ce61ec34ec95ec34c859854c89542b", downloadBytes: 1_601_108_840, vietnamese: .basic, thinking: false,
        files: ["chat_template.jinja", "config.json", "generation_config.json", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"],
        note: "Larger LFM with better answers.")

    static let lfm8bA1B = LocalModel(
        id: "lfm2.5-8b-a1b", family: .lfm, variant: "8B-A1B", repo: "LiquidAI/LFM2.5-8B-A1B-MLX-4bit",
        revision: "2e92b640a63d47ad4dcf81a19a366b902356b3bc", downloadBytes: 4_851_982_764, vietnamese: .basic, thinking: true,
        files: ["chat_template.jinja", "config.json", "generation_config.json", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"],
        note: "Mixture of experts: big-model answers at small-model speed.")

    static let minicpm1 = LocalModel(
        id: "minicpm5-1b", family: .minicpm, variant: "1B", repo: "openbmb/MiniCPM5-1B-MLX",
        revision: "9879b18bf2928355fcdf4287635388a3665a40cb", downloadBytes: 617_970_878, vietnamese: .basic, thinking: true,
        files: ["chat_template.jinja", "config.json", "generation_config.json", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"],
        note: "Compact and quick.")

    static let minicpm2 = LocalModel(
        id: "minicpm5-2b", family: .minicpm, variant: "2B", repo: "openbmb/MiniCPM5-2B-MLX",
        revision: "8a9ad7539ac86281d0ac2b017ba04a5de53fe9a3", downloadBytes: 1_426_008_802, vietnamese: .basic, thinking: true,
        files: ["chat_template.jinja", "config.json", "generation_config.json", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"],
        note: "Stronger reasoning in a small size.")

    static let bonsai1_7 = LocalModel(
        id: "bonsai-1.7b", family: .bonsai, variant: "1.7B", repo: "prism-ml/Ternary-Bonsai-1.7B-mlx-2bit",
        revision: "5f3e306330f636cfc6c6241b4850fae6711c5985", downloadBytes: 495_528_947, vietnamese: .basic, thinking: true,
        files: ["chat_template.jinja", "config.json", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"],
        note: "Smallest Bonsai, very light on memory.")

    static let bonsai4 = LocalModel(
        id: "bonsai-4b", family: .bonsai, variant: "4B", repo: "prism-ml/Ternary-Bonsai-4B-mlx-2bit",
        revision: "e1374ad6bf9b1b56afd743936b8faa33c409a75f", downloadBytes: 1_143_060_044, vietnamese: .basic, thinking: true,
        files: ["chat_template.jinja", "config.json", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"],
        note: "4B quality in a 1 GB download.")

    static let bonsai8 = LocalModel(
        id: "bonsai-8b", family: .bonsai, variant: "8B", repo: "prism-ml/Ternary-Bonsai-8B-mlx-2bit",
        revision: "9260b24298e4211e804663e9f519962cf59f34be", downloadBytes: 2_315_155_948, vietnamese: .basic, thinking: true,
        files: ["chat_template.jinja", "config.json", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"],
        note: "8B quality in a 2.3 GB download.")

    static let catalog = [qwen08, qwen2, qwen4, gemmaE2B, gemmaE4B,
                          lfm230m, lfm350m, lfm1_2, lfm1_2Thinking, lfm2_6, lfm8bA1B,
                          minicpm1, minicpm2, bonsai1_7, bonsai4, bonsai8]

    /// What we recommend, best first (from the Vietnamese parse eval in the PRs): the first one this phone runs
    /// comfortably. Speed counts: a model the phone holds but that is heavy for it is not recommended.
    static let ranking = [gemmaE2B, qwen2, qwen08]

    /// The phone can hold it: hidden from the screen otherwise.
    func runs(on d: DeviceMemory = .current) -> Bool { d.gpuSupported && ramBytes <= d.usable }

    /// Runs, but takes more than half of what iOS lets the app use: slower, warmer, more battery ("High CPU usage").
    func isHeavy(on d: DeviceMemory = .current) -> Bool { ramBytes > d.appLimit / 2 }

    /// nil = nothing runs comfortably: suggest Apple on-device or BYOK instead.
    static func recommended(on d: DeviceMemory = .current) -> LocalModel? {
        ranking.first { $0.runs(on: d) && !$0.isHeavy(on: d) }
    }

    static func runnable(on d: DeviceMemory = .current) -> [LocalModel] { catalog.filter { $0.runs(on: d) } }

    static func find(_ id: String?) -> LocalModel? { catalog.first { $0.id == id } }

    func url(_ file: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file)")!
    }
}

/// What this phone can give a local model.
struct DeviceMemory: Sendable, Equatable {
    var physical: Int64
    /// Most memory iOS lets this app use before it is killed (raised by the increased-memory-limit entitlement).
    var appLimit: Int64
    /// MLX needs an Apple GPU family 7 chip (A14 or newer).
    var gpuSupported = true

    /// Room for a model: the app itself (UI, SwiftData, MLX buffers) keeps the rest.
    var usable: Int64 { appLimit * 8 / 10 }

    static var current: DeviceMemory {
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        #if DEBUG
        // Screenshots / UI checks: `-localModelsRAMGB 8` pretends to be an 8 GB iPhone (limit ≈ 70 %).
        let gb = UserDefaults.standard.double(forKey: "localModelsRAMGB")
        if gb > 0 { return DeviceMemory(physical: Int64(gb * 1e9), appLimit: Int64(gb * 0.7e9)) }
        #endif
        return DeviceMemory(physical: physical, appLimit: appMemoryLimit(physical: physical), gpuSupported: gpuSupported)
    }

    /// The app's jetsam limit = what is left + what it already uses. Simulator/Mac report 0: assume half the RAM.
    private static func appMemoryLimit(physical: Int64) -> Int64 {
        #if os(iOS) && !targetEnvironment(simulator)
        let available = Int64(os_proc_available_memory())
        if available > 0 { return available + footprint() }
        #endif
        return physical / 2
    }

    private static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    private static let gpuSupported: Bool = {
        #if canImport(Metal)
        MTLCreateSystemDefaultDevice()?.supportsFamily(.apple7) ?? false
        #else
        false
        #endif
    }()
}
