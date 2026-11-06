import Foundation
import Observation

/// Where downloads live: `Application Support/Models/<id>/` (not backed up). A `.complete` marker means ready to load;
/// a half-fetched file keeps its URLSession resume data next to it as `<file>.resume`.
struct LocalModelStore: Sendable {
    var root: URL
    static let shared = LocalModelStore(root: .applicationSupportDirectory.appending(path: "Models"))

    func folder(_ m: LocalModel) -> URL { root.appending(path: m.id, directoryHint: .isDirectory) }
    private func marker(_ m: LocalModel) -> URL { folder(m).appending(path: ".complete") }

    func isDownloaded(_ m: LocalModel) -> Bool { FileManager.default.fileExists(atPath: marker(m).path) }

    func isFetched(_ m: LocalModel, _ file: String) -> Bool {
        FileManager.default.fileExists(atPath: folder(m).appending(path: file).path)
    }

    func resumeURL(_ m: LocalModel, _ file: String) -> URL { folder(m).appending(path: file + ".resume") }

    /// Bytes already on disk, counting the received part of an interrupted file.
    func bytesOnDisk(_ m: LocalModel) -> Int64 {
        m.files.reduce(0) { sum, file in
            let path = folder(m).appending(path: file).path
            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 { return sum + size }
            return sum + partialBytes(m, file)
        }
    }

    func partialBytes(_ m: LocalModel, _ file: String) -> Int64 {
        Self.receivedBytes(resumeData: try? Data(contentsOf: resumeURL(m, file)))
    }

    /// URLSession resume data is a plist that records how much arrived.
    static func receivedBytes(resumeData: Data?) -> Int64 {
        guard let resumeData,
              let plist = try? PropertyListSerialization.propertyList(from: resumeData, format: nil) as? [String: Any]
        else { return 0 }
        return (plist["NSURLSessionResumeBytesReceived"] as? NSNumber)?.int64Value ?? 0
    }

    func state(_ m: LocalModel) -> LocalModelDownloads.State {
        if isDownloaded(m) { return .downloaded }
        let bytes = bytesOnDisk(m)
        return bytes > 0 ? .paused(m.fraction(bytes)) : .notDownloaded
    }

    func prepareFolder(_ m: LocalModel) throws {
        var url = folder(m)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func markComplete(_ m: LocalModel) throws { try Data().write(to: marker(m)) }

    func delete(_ m: LocalModel) { try? FileManager.default.removeItem(at: folder(m)) }
}

extension LocalModel {
    func fraction(_ bytes: Int64) -> Double { min(1, Double(bytes) / Double(downloadBytes)) }
}

/// Downloads for the models screen: file by file, resumable, optionally Wi-Fi only.
@MainActor @Observable
final class LocalModelDownloads {
    enum State: Equatable, Sendable {
        case notDownloaded
        case downloading(Double)
        case waitingForWiFi(Double)
        case paused(Double)
        case downloaded
        case failed(String)
    }

    static let shared = LocalModelDownloads()
    static let wifiOnlyKey = "ai.local.wifiOnly"
    /// The downloaded model `AIRouter` uses in local/hybrid mode.
    static let selectedKey = "ai.local.model"

    enum Speed: Equatable, Sendable {
        case running
        case done(LocalRuntime.Metrics)
        case failed(String)
    }

    let store: LocalModelStore
    private(set) var states: [String: State] = [:]
    /// "Test speed" results on this phone, while the app runs.
    private(set) var speeds: [String: Speed] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    init(store: LocalModelStore = .shared) {
        self.store = store
        for m in LocalModel.catalog { states[m.id] = store.state(m) }
    }

    func state(_ m: LocalModel) -> State { states[m.id] ?? .notDownloaded }

    var wifiOnly: Bool { UserDefaults.standard.object(forKey: Self.wifiOnlyKey) as? Bool ?? true }

    func start(_ m: LocalModel) {
        guard tasks[m.id] == nil, store.state(m) != .downloaded else { return }
        let onDisk = store.bytesOnDisk(m)
        let free = (try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        if let free, free < m.downloadBytes - onDisk {
            states[m.id] = .failed(String(localized: "Not enough free space on this iPhone.", table: "LocalModels"))
            return
        }
        states[m.id] = .downloading(m.fraction(onDisk))
        let store = store, wifiOnly = wifiOnly
        tasks[m.id] = Task {
            do {
                try store.prepareFolder(m)
                for file in m.files where !store.isFetched(m, file) {
                    let base = store.bytesOnDisk(m) - store.partialBytes(m, file)
                    try await FileFetch.run(url: m.url(file), to: store.folder(m).appending(path: file),
                                            resume: store.resumeURL(m, file), wifiOnly: wifiOnly) { event in
                        Task { @MainActor in self.progress(m, event, base: base) }
                    }
                }
                try store.markComplete(m)
                states[m.id] = .downloaded
                if UserDefaults.standard.string(forKey: Self.selectedKey) == nil {
                    UserDefaults.standard.set(m.id, forKey: Self.selectedKey)
                }
            } catch is CancellationError {
                states[m.id] = store.state(m)
            } catch {
                states[m.id] = .failed(error.localizedDescription)
            }
            tasks[m.id] = nil
        }
    }

    func pause(_ m: LocalModel) { tasks[m.id]?.cancel() }

    func testSpeed(_ m: LocalModel) {
        guard speeds[m.id] != .running, state(m) == .downloaded else { return }
        speeds[m.id] = .running
        let llm = LocalLLM(model: m, folder: store.folder(m))
        Task {
            do { speeds[m.id] = .done(try await llm.benchmark()) } catch { speeds[m.id] = .failed(error.localizedDescription) }
        }
    }

    func delete(_ m: LocalModel) {
        tasks[m.id]?.cancel()
        store.delete(m)
        states[m.id] = .notDownloaded
        if UserDefaults.standard.string(forKey: Self.selectedKey) == m.id {
            UserDefaults.standard.removeObject(forKey: Self.selectedKey)
        }
        Task { await LocalRuntime.shared.unload() }
    }

    private func progress(_ m: LocalModel, _ event: FileFetch.Event, base: Int64) {
        guard tasks[m.id] != nil else { return }
        switch event {
        case .bytes(let n): states[m.id] = .downloading(m.fraction(base + n))
        case .waitingForWiFi: states[m.id] = .waitingForWiFi(m.fraction(base))
        }
    }
}

/// One file over URLSession with byte-level resume: on pause or a dropped connection the resume data is saved
/// next to the file, and the next run continues from it.
private final class FileFetch: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Event { case bytes(Int64), waitingForWiFi }

    private let destination: URL
    private let onEvent: @Sendable (Event) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?

    private init(destination: URL, onEvent: @escaping @Sendable (Event) -> Void) {
        (self.destination, self.onEvent) = (destination, onEvent)
    }

    static func run(url: URL, to destination: URL, resume: URL, wifiOnly: Bool,
                    onEvent: @escaping @Sendable (Event) -> Void) async throws {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true // Wi-Fi only: wait for Wi-Fi instead of failing
        config.allowsCellularAccess = !wifiOnly
        config.allowsExpensiveNetworkAccess = !wifiOnly
        config.timeoutIntervalForResource = 24 * 3600
        let fetch = FileFetch(destination: destination, onEvent: onEvent)
        let session = URLSession(configuration: config, delegate: fetch, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let task = (try? Data(contentsOf: resume)).map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
        try? FileManager.default.removeItem(at: resume)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    fetch.continuation = c
                    task.resume()
                }
            } onCancel: {
                task.cancel { data in try? data?.write(to: resume) }
            }
        } catch let error as URLError {
            if let data = error.downloadTaskResumeData { try? data.write(to: resume) }
            if error.code == .cancelled { throw CancellationError() }
            throw error
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        onEvent(.bytes(totalBytesWritten))
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        onEvent(.waitingForWiFi)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(code) else {
            moveError = URLError(.badServerResponse)
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? moveError { continuation?.resume(throwing: error) } else { continuation?.resume() }
        continuation = nil
    }
}
