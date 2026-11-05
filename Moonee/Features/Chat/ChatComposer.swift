import PhotosUI
import SwiftUI

/// The chat's input. Idle: one pill with (+), "Type or hold to talk", mic (dictate into the field) and a round voice
/// button (hold to talk, release to send). Typing: the pill grows into a card, the text on top and
/// (+) · model chip · mic · send below. One `AnyLayout` for both, so the text field keeps its focus.
struct ChatComposer: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    let isRecording: Bool
    let onPlus: () -> Void
    let onMic: () -> Void
    let onHoldStart: () -> Void
    let onHoldEnd: () -> Void
    let onSend: () -> Void
    let onChangeModel: () -> Void
    @State private var holding = false
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
                    sendButton
                }
            } else {
                micButton
                voiceButton
            }
        }
        .padding(.horizontal, 6).padding(.vertical, typing ? 8 : 4)
        .background(Color.surface, in: .rect(cornerRadius: typing ? 24 : 30))
        .overlay { if isRecording { RoundedRectangle(cornerRadius: typing ? 24 : 30).strokeBorder(Color.brandPrimary.opacity(0.6), lineWidth: 1.5) } }
        .shadow(color: .brandDeep.opacity(0.08), radius: 10, y: 3)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: typing)
    }

    private var field: some View {
        TextField(String(localized: "Type or hold to talk", table: "Chat"), text: $text, axis: .vertical)
            .font(.bodyText)
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
                        Text("Listening…", tableName: "Chat").font(.bodyText).foregroundStyle(Color.ink)
                    }
                    .padding(.horizontal, typing ? 10 : 4)
                    .accessibilityElement(children: .combine)
                }
            }
    }

    private var plusButton: some View {
        Button(action: onPlus) {
            Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.brandDeep)
                .frame(width: 34, height: 34).background(Color.brandMintSoft, in: .circle)
                .frame(width: 44, height: 44).contentShape(.circle)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(Text("Add to chat", tableName: "Chat"))
    }

    private var micButton: some View {
        Button(action: onMic) {
            Image(systemName: isRecording && !holding ? "stop.fill" : "mic")
                .font(.system(size: 18, weight: .medium)).foregroundStyle(isRecording && !holding ? Color.danger : Color.brandDeep)
                .frame(width: 44, height: 44).contentShape(.circle)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(isRecording ? Text("Stop recording", tableName: "Chat") : Text("Dictate", tableName: "Chat"))
    }

    /// Hold to talk: recording starts on touch-down and the message is sent on release.
    private var voiceButton: some View {
        Image(systemName: "waveform")
            .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(LinearGradient.brand, in: .circle)
            .scaleEffect(holding && !reduceMotion ? 1.15 : 1)
            .frame(width: 44, height: 44).contentShape(.circle)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !holding { holding = true; onHoldStart() } }
                .onEnded { _ in holding = false; onHoldEnd() })
            .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: holding)
            .accessibilityElement()
            .accessibilityLabel(Text("Hold to talk", tableName: "Chat"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { isRecording ? onHoldEnd() : onHoldStart() } // VoiceOver: double-tap to start, again to send
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                .frame(width: 38, height: 38).background(LinearGradient.brand, in: .circle)
                .frame(width: 44, height: 44).contentShape(.circle)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!canSend)
        .opacity(canSend ? 1 : 0.4)
        .accessibilityLabel(Text("Send", tableName: "Chat"))
    }
}

/// "DeepSeek · Medium": the model answering, with its reasoning effort. Tap to change the effort or the model.
struct ModelChip: View {
    let onChangeModel: () -> Void
    /// Effort is stored per provider + model (`LLMSettings.effort`); bumped to redraw after a change.
    @State private var changes = 0
    // Read so the chip updates when AI settings change.
    @AppStorage(LLMSettings.modeKey) private var modeRaw = ""
    @AppStorage(LLMSettings.cloudKey) private var cloudRaw = ""

    var body: some View {
        let efforts = LLMSettings.supportedEffortsNow
        let effort = Binding(get: { LLMSettings.effort }, set: { LLMSettings.effort = $0; changes += 1 })
        Menu {
            if !efforts.isEmpty {
                Picker(selection: effort) {
                    ForEach(efforts, id: \.self) { Text(Self.title($0)).tag($0) }
                } label: { Text("Effort", tableName: "Chat") }
                .pickerStyle(.inline)
            }
            Button(action: onChangeModel) {
                Label { Text("Change model…", tableName: "Chat") } icon: { Image(systemName: "slider.horizontal.3") }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkle").font(.caption).foregroundStyle(Color.brandPrimary)
                Text(label).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.chip)
            .foregroundStyle(Color.brandDeep)
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color.brandMintSoft, in: .capsule)
            .frame(minHeight: 44).contentShape(.rect)
        }
        .accessibilityLabel(Text("Model: \(label)", tableName: "Chat"))
    }

    private var label: String {
        _ = changes
        return LLMSettings.supportedEffortsNow.isEmpty ? Self.modelName : "\(Self.modelName) · \(Self.title(LLMSettings.effort))"
    }

    static var modelName: String {
        switch LLMSettings.mode {
        case .onDevice: return "Apple"
        case .local: return String(localized: "On-device", table: "Chat")
        case .byok, .hybrid:
            let p = LLMSettings.cloudProvider
            switch p {
            case .openRouter: return "OpenRouter"
            case .deepSeek: return "DeepSeek"
            case .openAI: return "OpenAI"
            case .anthropic: return "Anthropic"
            case .gemini: return "Gemini"
            case .custom: return LLMSettings.model(p).split(separator: "/").last.map(String.init) ?? "Custom"
            }
        }
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

/// "Add to chat": camera and recent photos (system picker, no library permission needed), receipt photo, skills, web search settings.
struct AddToChatSheet: View {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var item: PhotosPickerItem?
    @State private var showLibrary = false
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
                                    Text("Camera", tableName: "Chat").font(.chip)
                                }
                                .foregroundStyle(Color.brandDeep)
                                .frame(width: 88, height: 88)
                                .background(Color.brandMintSoft, in: .rect(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                        }
                        PhotosPicker(selection: $item, matching: .images) { EmptyView() }
                            .photosPickerStyle(.compact)
                            .photosPickerDisabledCapabilities(.selectionActions)
                            .photosPickerAccessoryVisibility(.hidden, edges: .all)
                            .frame(height: 88)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
                Section {
                    Button { showLibrary = true } label: {
                        Label { Text("Choose receipt photo", tableName: "Chat") } icon: { Image(systemName: "doc.text.image") }
                    }
                    NavigationLink { SkillsView() } label: {
                        Label { Text("Skills", tableName: "Chat") } icon: { Image(systemName: "wand.and.stars") }
                    }
                    // Search turns on in AI settings (a provider with built-in search, or a Tavily / Brave key).
                    NavigationLink { AISettingsView() } label: {
                        LabeledContent {
                            SearchSettings.backend() == nil ? Text("Not set up", tableName: "Chat") : Text("On", tableName: "Chat")
                        } label: {
                            Label { Text("Web search", tableName: "Chat") } icon: { Image(systemName: "globe") }
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
            .photosPicker(isPresented: $showLibrary, selection: $item, matching: .images)
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in pick(image) }.ignoresSafeArea()
            }
            .onChange(of: item) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { pick(image) }
                }
            }
        }
    }

    private func pick(_ image: UIImage) {
        dismiss()
        onImage(image)
    }
}

/// Where a web answer came from: site · time, opening the page.
struct SourceChips: View {
    let sources: [SearchHit]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sources.filter { URL(string: $0.url) != nil }, id: \.url) { s in
                    Link(destination: URL(string: s.url)!) {
                        HStack(spacing: 4) {
                            Image(systemName: "globe").font(.caption)
                            Text(Self.site(s)).lineLimit(1)
                            if let date = s.date, !date.isEmpty {
                                Text(verbatim: "· \(date)").lineLimit(1) // as the source gives it ("2 hours ago", "2026-11-05")
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

    /// "vnexpress.net" from the page URL.
    static func site(_ s: SearchHit) -> String {
        guard let host = URL(string: s.url)?.host() else { return s.title }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
