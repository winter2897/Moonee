import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The chat's input. Idle: one pill with (+), "Type or hold to talk", mic and camera. Typing: the pill grows into a card,
/// the text on top and (+) · model chip · mic · camera · send below (send only once there is text).
/// One `AnyLayout` for both, so the text field keeps its focus.
/// The mic: tap to start, tap again to send what was heard; or hold to talk and let go to send.
struct ChatComposer: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    /// Starting or recording (`SpeechInput.isActive`).
    let isRecording: Bool
    let onPlus: () -> Void
    let onVoiceStart: () -> Void
    let onVoiceEnd: () -> Void
    let onCamera: () -> Void
    let onSend: () -> Void
    let onChangeModel: () -> Void
    @State private var pressedAt: Date?
    /// This touch began while recording: it ends the recording (tap-to-stop).
    @State private var stopOnRelease = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var typing: Bool { focus.wrappedValue || !text.isEmpty }
    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        let layout = typing ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 2))
        layout {
            if !typing { plusButton }
            field
            if typing {
                HStack(spacing: 2) {
                    plusButton
                    ModelChip(onChangeModel: onChangeModel)
                    Spacer(minLength: 4)
                    micButton
                    cameraButton
                    if canSend { sendButton }
                }
            } else {
                micButton
                cameraButton
            }
        }
        .padding(.horizontal, 6).padding(.vertical, typing ? 8 : 4)
        .background(Color.surface, in: .rect(cornerRadius: typing ? 24 : 30))
        .overlay { if isRecording { RoundedRectangle(cornerRadius: typing ? 24 : 30).strokeBorder(Color.brandPrimary.opacity(0.6), lineWidth: 1.5) } }
        .shadow(color: .brandDeep.opacity(0.08), radius: 10, y: 3)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: typing)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: canSend)
    }

    private var field: some View {
        TextField(String(localized: "Type or hold to talk", table: "Chat"), text: $text, axis: .vertical)
            .font(.body)
            .foregroundStyle(Color.ink)
            .lineLimit(typing ? 1...6 : 1...1)
            .focused(focus)
            .padding(.horizontal, typing ? 10 : 4)
            .frame(minHeight: 44)
            .opacity(isRecording ? 0 : 1)
            .overlay(alignment: .leading) {
                if isRecording {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform").foregroundStyle(Color.brandPrimary)
                            .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                        Text(pressedAt == nil ? "Listening… tap to send" : "Listening… let go to send", tableName: "Chat")
                            .font(.body).foregroundStyle(Color.ink).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, typing ? 10 : 4)
                    .accessibilityElement(children: .combine)
                }
            }
    }

    private var plusButton: some View {
        Button {
            focus.wrappedValue = false // the sheet opens over a closed keyboard; the field never takes this tap
            onPlus()
        } label: {
            Image(systemName: "plus").font(.body.weight(.semibold)).foregroundStyle(Color.brandDeep)
                .frame(width: 34, height: 34).background(Color.brandMintSoft, in: .circle)
                .frame(width: 44, height: 44).contentShape(.circle)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(Text("Add to chat", tableName: "Chat"))
    }

    /// Tap: start, tap again: send. Hold: talk, let go: send. Recording starts on touch-down either way.
    private var micButton: some View {
        let recordingTap = isRecording && pressedAt == nil
        return Image(systemName: recordingTap ? "arrow.up" : "mic.fill")
            .font(.body.weight(.semibold))
            .foregroundStyle(isRecording ? .white : Color.brandDeep)
            .frame(width: 36, height: 36)
            .background(isRecording ? AnyShapeStyle(LinearGradient.brand) : AnyShapeStyle(Color.clear), in: .circle)
            .scaleEffect(pressedAt != nil && isRecording && !reduceMotion ? 1.15 : 1)
            .frame(width: 44, height: 44).contentShape(.circle)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard pressedAt == nil else { return }
                    pressedAt = .now
                    stopOnRelease = isRecording
                    if !isRecording { onVoiceStart() }
                }
                .onEnded { _ in
                    let held = pressedAt.map { Date.now.timeIntervalSince($0) > 0.4 } ?? false
                    pressedAt = nil
                    if stopOnRelease || held { onVoiceEnd() }
                })
            .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: pressedAt)
            .accessibilityElement()
            .accessibilityLabel(isRecording ? Text("Send voice message", tableName: "Chat") : Text("Voice message", tableName: "Chat"))
            .accessibilityHint(isRecording ? Text(verbatim: "") : Text("Hold to talk, or tap to start and tap again to send.", tableName: "Chat"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { isRecording ? onVoiceEnd() : onVoiceStart() }
    }

    private var cameraButton: some View {
        Button {
            focus.wrappedValue = false
            onCamera()
        } label: {
            Image(systemName: "camera").font(.body.weight(.semibold)).foregroundStyle(Color.brandDeep)
                .frame(width: 44, height: 44).contentShape(.circle)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(isRecording)
        .accessibilityLabel(Text("Take a photo of a receipt", tableName: "Chat"))
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(.white)
                .frame(width: 36, height: 36).background(LinearGradient.brand, in: .circle)
                .frame(width: 44, height: 44).contentShape(.circle)
        }
        .buttonStyle(PressScaleStyle())
        .transition(.scale.combined(with: .opacity))
        .accessibilityLabel(Text("Send", tableName: "Chat"))
    }
}

/// The engine that actually answers in the chat right now, as the router will pick it (not just the chosen mode).
enum ChatEngine: Equatable {
    case apple
    case local(String)
    case cloud(CloudProvider, model: String)
    /// BYOK chosen but no key yet: the rule parser answers until one is added.
    case needsKey(CloudProvider)
    /// No model at all: the rule parser and the plain numbers.
    case offline

    static func current(_ router: AIRouter = LLMSettings.router(), provider: CloudProvider = LLMSettings.cloudProvider,
                        model: String? = nil) -> ChatEngine {
        if let first = router.candidates(for: .quickAnswer).first {
            if first is AppleLLM { return .apple }
            if let l = first as? LocalLLM { return .local(l.model.name) }
            return .cloud(provider, model: model ?? LLMSettings.model(provider))
        }
        return router.mode == .byok || router.mode == .hybrid ? .needsKey(provider) : .offline
    }

    /// "gemini-3.5-flash-lite", "Apple Intelligence", "Offline"; the effort is appended when the model has one.
    func label(effort: ReasoningEffort?) -> String {
        let name: String = switch self {
        case .apple: "Apple Intelligence"
        case .local(let model): model
        // The short model name already says whose it is (gemini-…, claude-…, deepseek-…); the provider is in settings.
        case .cloud(let p, let model):
            model.split(separator: "/").last.map(String.init) ?? Self.providerName(p) ?? model
        case .needsKey: String(localized: "Add key", table: "Chat")
        case .offline: String(localized: "Offline", table: "Chat")
        }
        return effort.map { "\(name) · \(ModelChip.title($0))" } ?? name
    }

    static func providerName(_ p: CloudProvider) -> String? {
        switch p {
        case .openRouter: "OpenRouter"
        case .deepSeek: "DeepSeek"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        case .custom: nil
        }
    }
}

/// The engine answering, with its reasoning effort. Tap to change the effort or the model;
/// with BYOK but no key it says "Add key" and opens AI settings.
struct ModelChip: View {
    let onChangeModel: () -> Void
    /// Effort is stored per provider + model (`LLMSettings.effort`); bumped to redraw after a change.
    @State private var changes = 0
    // Read so the chip updates when AI settings change.
    @AppStorage(LLMSettings.modeKey) private var modeRaw = ""
    @AppStorage(LLMSettings.cloudKey) private var cloudRaw = ""

    var body: some View {
        let engine = ChatEngine.current()
        let efforts = LLMSettings.supportedEffortsNow
        let effort = { _ = changes; return efforts.isEmpty ? nil : LLMSettings.effort }()
        let label = engine.label(effort: effort)
        Group {
            if case .needsKey = engine {
                Button(action: onChangeModel) { chip(label, effort: nil, symbol: "key.fill", chevron: false) }
                    .accessibilityHint(Text("Opens AI settings", tableName: "Chat"))
            } else {
                Menu {
                    if !efforts.isEmpty {
                        Picker(selection: Binding(get: { LLMSettings.effort }, set: { LLMSettings.effort = $0; changes += 1 })) {
                            ForEach(efforts, id: \.self) { Text(Self.title($0)).tag($0) }
                        } label: { Text("Effort", tableName: "Chat") }
                        .pickerStyle(.inline)
                    }
                    Button(action: onChangeModel) {
                        Label { Text("Change model…", tableName: "Chat") } icon: { Image(systemName: "slider.horizontal.3") }
                    }
                } label: {
                    chip(engine.label(effort: nil), effort: effort, symbol: engine == .offline ? "bolt.horizontal" : "sparkle", chevron: true)
                }
            }
        }
        .accessibilityLabel(Text("Model: \(label)", tableName: "Chat"))
    }

    /// Only the model name truncates; the effort always shows.
    private func chip(_ name: String, effort: ReasoningEffort?, symbol: String, chevron: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption).foregroundStyle(Color.brandPrimary)
            Text(name).lineLimit(1)
            if let effort { Text(verbatim: "· \(Self.title(effort))").lineLimit(1).fixedSize() }
            if chevron { Image(systemName: "chevron.down").font(.caption2.weight(.semibold)) }
        }
        .font(.chip)
        .foregroundStyle(Color.brandDeep)
        .padding(.horizontal, 10).frame(height: 30)
        .background(Color.brandMintSoft, in: .capsule)
        .frame(minHeight: 44).contentShape(.rect)
    }

    static func title(_ e: ReasoningEffort) -> String {
        switch e {
        case .low: String(localized: "Low", table: "Chat")
        case .medium: String(localized: "Medium", table: "Chat")
        case .high: String(localized: "High", table: "Chat")
        case .higher: String(localized: "Higher", table: "Chat")
        case .max: String(localized: "Max", table: "Chat")
        }
    }
}

/// "Add to chat": camera and recent photos (system picker, no library permission needed), a file (photo or PDF),
/// skills, web search settings.
struct AddToChatSheet: View {
    let onImage: (UIImage) -> Void
    let onPDF: (PDFDocument, String) -> Void
    let onUnreadable: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var item: PhotosPickerItem?
    @State private var webSearch = LLMSettings.webSearch
    @State private var showFiles = false
    @State private var showCamera = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button { showCamera = true } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: "camera.fill").font(.title2)
                                    Text("Camera", tableName: "Chat").font(.footnote.weight(.semibold))
                                }
                                .foregroundStyle(Color.brandDeep)
                                .frame(width: 88).frame(maxHeight: .infinity)
                                .background(Color.brandMintSoft, in: .rect(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Take a photo of a receipt", tableName: "Chat"))
                        }
                        // The system's own strip of recent photos: tap one to read it as a receipt.
                        PhotosPicker(selection: $item, matching: .images, preferredItemEncoding: .compatible) { EmptyView() }
                            .photosPickerStyle(.compact)
                            .photosPickerDisabledCapabilities([.selectionActions, .collectionNavigation, .search])
                            .photosPickerAccessoryVisibility(.hidden, edges: .all)
                    }
                    .frame(height: 120)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
                Section {
                    Button { showFiles = true } label: {
                        Label { Text("Add file", tableName: "Chat") } icon: { Image(systemName: "doc.badge.plus") }
                    }
                    NavigationLink { SkillsView() } label: {
                        Label { Text("Skills", tableName: "Chat") } icon: { Image(systemName: "wand.and.stars") }
                    }
                    Toggle(isOn: $webSearch) {
                        Label { Text("Web search", tableName: "Chat") } icon: { Image(systemName: "globe") }
                    }
                    // Search also needs a backend: a provider with built-in search, or a Tavily / Brave key (AI settings).
                    if webSearch, SearchSettings.backend() == nil {
                        NavigationLink { AISettingsView() } label: {
                            Text("Set up web search", tableName: "Chat").font(.subheadline).foregroundStyle(Color.brandDeep)
                        }
                    }
                }
                .foregroundStyle(Color.ink)
                .tint(.brandPrimary)
            }
            .navigationTitle(Text("Add to chat", tableName: "Chat"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel(Text("Close", tableName: "Chat"))
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image, .pdf]) { result in
                guard case .success(let url) = result else { return }
                open(url)
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in pick(image) }.ignoresSafeArea()
            }
            .onChange(of: webSearch) { _, on in LLMSettings.webSearch = on }
            .onChange(of: item) { _, picked in
                guard let picked else { return }
                Task {
                    let data = try? await picked.loadTransferable(type: Data.self)
                    item = nil // the same photo can be picked again
                    if let data, let image = UIImage(data: data) { pick(image) } else { dismiss(); onUnreadable() }
                }
            }
        }
    }

    /// A picked file: an image goes to OCR, a PDF to its text (or OCR of its pages).
    private func open(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        dismiss()
        let data = try? Data(contentsOf: url) // read now: access ends with this function
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true, let data, let pdf = PDFDocument(data: data) {
            onPDF(pdf, url.lastPathComponent)
        } else if let data, let image = UIImage(data: data) {
            onImage(image)
        } else {
            onUnreadable()
        }
    }

    private func pick(_ image: UIImage) {
        dismiss()
        onImage(image)
    }
}

/// Where a web answer came from: site · time, opening the page.
struct SourceChips: View {
    let sources: [WebSource]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sources, id: \.url) { s in
                    Link(destination: s.url) {
                        HStack(spacing: 4) {
                            Image(systemName: "globe").font(.caption)
                            Text(s.site).lineLimit(1)
                            if let date = s.date {
                                Text(verbatim: "·")
                                Text(date, format: .relative(presentation: .named)).lineLimit(1)
                            }
                        }
                        .font(.chip)
                        .foregroundStyle(Color.brandDeep)
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(Color.surface, in: .capsule)
                        .frame(minHeight: 44)
                    }
                    .accessibilityHint(Text(s.title))
                }
            }
        }
        .accessibilityLabel(Text("Sources", tableName: "Chat"))
    }
}
