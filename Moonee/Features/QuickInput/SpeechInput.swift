import AVFoundation
@preconcurrency import Speech

/// Live dictation in the app's language (on-device when the model is installed). `transcript` updates as the user speaks.
/// `start()`, then `finish()` (waits for the final words) or `stop()`. A stop that comes while the permission prompts
/// are still up is kept, so a quick tap never leaves the mic running.
@Observable @MainActor final class SpeechInput {
    enum Failure: Equatable { case denied, unavailable, noMicrophone, failed }

    var transcript = ""
    private(set) var isRecording = false
    /// Asking for permission / starting the engine; `isRecording` follows once audio flows.
    private(set) var isStarting = false
    var failure: Failure?
    var isActive: Bool { isStarting || isRecording }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var stopRequested = false
    /// Bumped per recording, so a late callback from the previous one changes nothing.
    private var run = 0

    /// Set when the app's language has no recognizer and dictation runs in a neighbour (Lao → Thai); the chat says so.
    private(set) var fallbackLocale: Locale?

    /// Languages Speech doesn't recognise (no lo-LA as of iOS 26) → the closest one it does.
    nonisolated static let fallbacks = ["lo": "th"]
    nonisolated static let preferred = ["vi": "vi-VN", "th": "th-TH", "lo": "lo-LA", "en": "en-US"]

    /// The recognizer locale for the app's language, e.g. vi-VN, th-TH; nil when the device has none.
    nonisolated static func recognizerLocale(app: String? = Bundle.main.preferredLocalizations.first,
                                             region: String? = Locale.current.region?.identifier,
                                             supported: Set<Locale> = SFSpeechRecognizer.supportedLocales()) -> Locale? {
        let lang = String((app ?? "vi").prefix(2))
        let matches = supported.filter { $0.language.languageCode?.identifier == lang }
        guard !matches.isEmpty else { return fallbacks[lang].flatMap { recognizerLocale(app: $0, region: region, supported: supported) } }
        return matches.first { $0.region?.identifier == region }
            ?? matches.first { $0.identifier == preferred[lang] }
            ?? matches.sorted { $0.identifier < $1.identifier }.first
    }

    func start() async {
        guard !isActive else { return }
        (failure, stopRequested, isStarting, transcript) = (nil, false, true, "")
        run += 1
        let run = run
        defer { isStarting = false }

        // Speech first, then the microphone: two system prompts, one after the other. Both answer off the main thread.
        let speechOK = SFSpeechRecognizer.authorizationStatus() == .authorized ? true : await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in c.resume(returning: status == .authorized) }
        }
        guard speechOK, await AVAudioApplication.requestRecordPermission() else { failure = .denied; return }
        guard let locale = Self.recognizerLocale(), let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            failure = .unavailable
            return
        }
        let app = Bundle.main.preferredLocalizations.first.map { String($0.prefix(2)) }
        if locale.language.languageCode?.identifier != app { fallbackLocale = locale }
        guard !stopRequested else { return } // released while the prompts were up

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0) // read once the session is active: the hardware format
            guard format.sampleRate > 0, format.channelCount > 0 else { failure = .noMicrophone; cleanUp(); return }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in request.append(buffer) } // audio thread
            engine.prepare()
            try engine.start()
            self.request = request
            isRecording = true
            task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let done = error != nil || result?.isFinal == true
                // 1110 = no speech, 1101/216/301 = cancelled or ended: not failures; the chat says it heard nothing.
                let failed = error.map { ![1110, 1101, 216, 301].contains(($0 as NSError).code) } ?? false
                Task { @MainActor in
                    guard let self, self.run == run else { return }
                    if let text, !text.isEmpty { self.transcript = text }
                    if done {
                        // After the user stopped, an error just means nothing was said: the chat says so (`finish` → "").
                        if failed, self.transcript.isEmpty, !self.stopRequested { self.failure = .failed }
                        self.cleanUp()
                        self.task = nil
                    }
                }
            }
        } catch {
            failure = .failed
            cleanUp()
        }
    }

    /// Ends audio; the recognizer still delivers the final transcript (`finish` waits for it).
    func stop() {
        stopRequested = true
        guard isRecording else { return }
        request?.endAudio()
        cleanUp()
    }

    /// Stops and waits, at most `timeout`, for the recognizer's final words; returns what was heard.
    // ponytail: polls every 50 ms; a continuation is only worth it if this ever runs hot.
    func finish(timeout: Duration = .seconds(2)) async -> String {
        stop()
        let deadline = ContinuousClock.now + timeout
        while task != nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        task?.finish()
        task = nil
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanUp() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
