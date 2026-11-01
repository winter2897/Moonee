import AVFoundation
import Speech

/// Live vi-VN dictation (on-device when the model is installed). `transcript` updates as the user speaks.
@Observable @MainActor final class SpeechInput {
    var transcript = ""
    var isRecording = false
    var error: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "vi-VN"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() async {
        error = nil
        let speechOK = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speechOK, await AVAudioApplication.requestRecordPermission() else {
            error = "Hãy cho phép Micro và Nhận dạng giọng nói trong Cài đặt."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            error = "Nhận dạng tiếng Việt chưa sẵn sàng trên máy này."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            let input = engine.inputNode
            // @Sendable: these run off the main actor (audio / recognizer threads).
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { @Sendable buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()

            self.request = request
            transcript = ""
            isRecording = true
            task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let done = error != nil || result?.isFinal == true
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if done { self.stop(); self.task = nil }
                }
            }
        } catch {
            self.error = "Không bật được micro: \(error.localizedDescription)"
            stop()
        }
    }

    /// Ends audio; the recognizer still delivers the final transcript.
    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
