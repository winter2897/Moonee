import PDFKit
import PhotosUI
import SwiftData
import SwiftUI

/// The Moonee chat (spec §3.1–3.3), opened by the (+) tab: type, say or snap a transaction, ask about money.
struct ChatView: View {
    var onBack: (() -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Query(sort: \ChatMessage.date) private var allMessages: [ChatMessage]
    /// The conversation on screen; nil until the first message of the day.
    @State private var thread: ChatThread?
    /// Reopened from history: it keeps going even on a later day.
    @State private var resumed = false
    @State private var text = ""
    @State private var inputSource = TxSource.text
    @FocusState private var focused: Bool
    @State private var busy = false
    @State private var mood = MooneeMood.greeting
    /// Parsed without an amount; Moonee asked "how much?" and the next message fills it in.
    @State private var pending: ParsedTxn?
    @State private var editingCard: PersistentIdentifier?
    @State private var editTxn: Txn?
    @State private var speech = SpeechInput()
    @State private var showAdd = false
    @State private var showHistory = false
    @State private var showAISettings = false
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var savedCount = 0
    @State private var showReport = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        // Moonee and the hills open the conversation, then scroll away with it: the chat gets the screen.
                        MooneeHero(mood: currentMood)
                            .animation(.smooth, value: currentMood)
                            .padding(.bottom, -14)
                        greeting
                        ForEach(messages.indices, id: \.self) { i in row(i) }
                        if busy {
                            ChatBubble(.moonee, "…").transition(.opacity)
                        } else if !choices.isEmpty {
                            choiceChips
                        } else if let last = messages.last, !last.fromUser {
                            tiles
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
                }
                // Messages fade out under the hero instead of being cut at its edge.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 22)
                        Color.black
                    }
                }
                // The keyboard gets out of the way: drag the chat (it bounces even when short) or tap outside a control.
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.always)
                .contentShape(.rect)
                .onTapGesture { focused = false }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .defaultScrollAnchor(.top, for: .alignment) // a short chat sits under the hero, as in the mockup
                .onChange(of: messages.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: busy) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            ChatComposer(text: $text, focus: $focused, isRecording: speech.isActive,
                         onPlus: { showAdd = true }, onVoiceStart: startVoice, onVoiceEnd: endVoice, onCamera: openCamera,
                         onSend: { send(text) }, onChangeModel: { showAISettings = true })
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 10)
        }
        .background(MooneeBackground())
        .onAppear {
            ChatThreads.migrate(in: context)
            if thread == nil { thread = ChatThreads.todays(in: context) }
            // Opens as the idle pill (owner's reference): type, or hold the voice button to talk.
        }
        .onChange(of: speech.transcript) { _, t in
            guard !t.isEmpty, speech.isRecording else { return }
            text = t
            inputSource = .voice
        }
        .onChange(of: speech.failure) { _, f in if let f { reply(ChatLines.voice(f), mood: .confused) } }
        .sheet(isPresented: $showAdd) {
            AddToChatSheet(onImage: { image in Task { await scan(image) } },
                           onPDF: { pdf, name in Task { await scan(pdf, name: name) } },
                           onUnreadable: { reply(ChatLines.unreadableFile, mood: .confused) })
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in Task { await scan(image) } }.ignoresSafeArea()
        }
        .photosPicker(isPresented: $showLibrary, selection: $libraryItem, matching: .images)
        .onChange(of: libraryItem) { _, picked in
            guard let picked else { return }
            Task {
                let data = try? await picked.loadTransferable(type: Data.self)
                libraryItem = nil
                if let data, let image = UIImage(data: data) { await scan(image) } else { reply(ChatLines.unreadableFile, mood: .confused) }
            }
        }
        .sheet(isPresented: $showHistory) {
            ChatHistoryView(onOpen: { t in (thread, resumed, pending) = (t, true, nil) },
                            onNew: newChat)
        }
        .sheet(isPresented: $showAISettings) { NavigationStack { AISettingsView() } }
        .sheet(item: $editTxn) { TxnEditForm(txn: $0) }
        .sheet(isPresented: $showReport) { ReportSheet() }
        .sensoryFeedback(.success, trigger: savedCount)
    }

    // MARK: Header

    private var currentMood: MooneeMood { speech.isRecording ? .listening : busy ? .thinking : mood }

    /// Back · the conversation's name · history. Moonee herself is at the top of the chat, not here.
    private var header: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 44, height: 44).overlay {
                if let onBack {
                    Button(action: onBack) { HeaderCircle("chevron.left") }.accessibilityLabel(Text("Back", tableName: "Chat"))
                }
            }
            Text(thread?.displayTitle ?? ChatThreads.dailyTitle(.now))
                .font(.headline).foregroundStyle(Color.brandDeep)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            Button { showHistory = true } label: { HeaderCircle("clock.arrow.circlepath") }
                .accessibilityLabel(Text("Chat history", tableName: "Chat"))
        }
        .padding(.horizontal, 16).padding(.bottom, 4)
    }

    // MARK: Messages

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChatBubble(.moonee, String(localized: "**Hi there!**\nWhat can Moonee do for you today? Log a spend, ask about your money, or snap a receipt.", table: "Chat"))
            // One row when the three fit (mockup), else the third wraps: never cut off at the edge (UI review C-3).
            let say = QuickReplyChip(title: String(localized: "Say a spend", table: "Chat"), symbol: "mic", action: startVoice)
            let scan = QuickReplyChip(title: String(localized: "Scan a receipt", table: "Chat"), symbol: "camera", action: openCamera)
            let type = QuickReplyChip(title: String(localized: "Type it in", table: "Chat"), symbol: "pencil") { focused = true }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { say; scan; type }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { say; scan }
                    type
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private func row(_ i: Int) -> some View {
        let m = messages[i]
        if m.fromUser {
            ChatBubble(.user, m.text, sent: true)
        } else {
            ChatBubble(.moonee, m.text, showsAvatar: i == 0 || messages[i - 1].fromUser)
            if !m.sources.isEmpty { SourceChips(sources: m.sources).padding(.leading, 48) }
            card(m)
        }
    }

    @ViewBuilder private func card(_ m: ChatMessage) -> some View {
        if m.undone {
            ChatTransactionCard(items: ChatBook.undoneLines(m).map { $0.item() }, state: .undone)
                .padding(.leading, 20)
        } else {
            let txns = m.savedTxns
            if !txns.isEmpty {
                let rows = txns.map { (item: ChatCardLine($0).item(), txn: $0) }
                let editing = editingCard == m.persistentModelID
                ChatTransactionCard(
                    items: rows.map(\.item), state: editing ? .editing : .saved,
                    onUndo: { withAnimation { ChatBook.undo(m, in: context); editingCard = nil } },
                    // One line: straight to the editor. Several: pick the line first.
                    onStartEditing: { if txns.count == 1 { editTxn = txns[0] } else { withAnimation { editingCard = m.persistentModelID } } },
                    onEdit: { id in editTxn = rows.first { $0.item.id == id }?.txn },
                    onDoneEditing: { withAnimation { editingCard = nil } })
                    .contentShape(.rect)
                    .onTapGesture { if !editing { withAnimation { editingCard = m.persistentModelID } } }
                    .accessibilityAction(named: Text("Edit", tableName: "Chat")) { editingCard = m.persistentModelID }
                    .padding(.leading, 20)
            }
        }
    }

    private var messages: [ChatMessage] {
        guard let thread else { return [] }
        return allMessages.filter { $0.thread == thread }
    }

    /// Every message goes into the right thread: a new day starts a new one (`ChatThreads.forNewMessage`).
    private func post(_ m: ChatMessage) {
        let t = ChatThreads.forNewMessage(open: thread, resumed: resumed, in: context)
        if t != thread { (thread, resumed) = (t, false) }
        let naming = t.isManual && t.title.isEmpty && m.fromUser
        context.insert(m)
        ChatThreads.add(m, to: t)
        // A manual chat is named after what it's about: the first sentence now, the model's short title when it answers.
        if naming {
            let first = m.text
            Task {
                if let title = await ChatThreads.modelTitle(for: first, using: LLMSettings.router().candidates(for: .quickAnswer).first) {
                    t.title = title
                    try? context.save()
                }
            }
        }
    }

    private func newChat() {
        (thread, resumed, pending, editingCard) = (ChatThreads.start(in: context), true, nil, nil)
    }

    /// Wallets or jars to pick when Moonee asked where a transfer goes.
    private var choices: [String] {
        guard let p = pending else { return [] }
        let book = ChatBook.Lookup(context)
        return book.unresolved(p).map { book.choices($0, for: p) } ?? []
    }

    private var choiceChips: some View {
        let chips = ForEach(choices, id: \.self) { name in QuickReplyChip(title: name) { send(name) } }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chips }
            VStack(alignment: .leading, spacing: 8) { chips }
        }
        .padding(.leading, 48)
    }

    private var tiles: some View {
        HStack(alignment: .top, spacing: 10) {
            QuickReplyChip(title: String(localized: "See monthly report", table: "Chat"), symbol: "chart.bar.fill", style: .tile) {
                showReport = true // S10: opens the report screen (Features/Report)
            }
            QuickReplyChip(title: String(localized: "How much is left in my Play jar?", table: "Chat"), symbol: "takeoutbag.and.cup.and.straw.fill", style: .tile) {
                send(String(localized: "How much is left in my Play jar?", table: "Chat"))
            }
            QuickReplyChip(title: String(localized: "Month-end saving tips", table: "Chat"), symbol: "target", style: .tile) {
                send(String(localized: "Month-end saving tips", table: "Chat"))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions

    private func send(_ raw: String) {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !busy else { return }
        if speech.isRecording { speech.stop() }
        let source = inputSource
        (text, inputSource, editingCard) = ("", .text, nil)
        let history = messages.suffix(10).map { LLMMessage(role: $0.fromUser ? .user : .assistant, text: $0.text) }
        post(ChatMessage(fromUser: true, text: input))
        let parser = ParserContext(context)

        // An answer to Moonee's question ("45k", "Vietcombank") fills the waiting transaction;
        // an amount only counts when the message is not a new transaction of its own.
        if var p = pending, let field = ChatBook.Lookup(context).unresolved(p),
           field != .amount || QuickParser.parse(input, context: parser).count <= 1,
           ChatBook.fill(&p, field, from: input, context: parser) {
            pending = nil
            record([p], source: source, raw: input)
            return
        }
        pending = nil

        busy = true
        let assistant = Assistant(router: LLMSettings.router(), tools: MooneeTools(ledger: StoreLedger(context)), catalog: SkillCatalog(context))
        Task {
            let out = await assistant.handle(input, history: history, context: parser)
            withAnimation { busy = false }
            switch out {
            case .transactions(let txns, _): record(txns, source: source, raw: input)
            case .answer(let answer, _, let sources): reply(answer, mood: .happy, sources: sources)
            case .facts(let facts, _):
                if let t = ChatBook.factsText(facts) { reply(t, mood: .happy, sources: ChatBook.sources(facts)) }
                else { reply(ChatLines.confused(), mood: .confused) }
            }
        }
    }

    /// Saves right away (spec §3.2) and shows the card; asks for what is missing instead of guessing.
    private func record(_ parsed: [ParsedTxn], source: TxSource, raw: String) {
        let saved = ChatBook.save(parsed, source: source, rawInput: raw, in: context)
        if !saved.isEmpty {
            let m = ChatMessage(fromUser: false, text: ChatLines.saved(saved))
            post(m)
            m.txns = saved
            mood = .happy
            savedCount += 1
        }
        let book = ChatBook.Lookup(context)
        if let ask = parsed.first(where: { book.unresolved($0) != nil }), let field = book.unresolved(ask) {
            if [.toWallet, .jar, .toJar].contains(field), book.choices(field, for: ask).isEmpty {
                reply(ChatLines.oneWallet, mood: .confused)
            } else {
                pending = ask
                reply(ChatLines.question(field, ask), mood: .confused)
            }
        } else if saved.isEmpty {
            reply(ChatLines.confused(), mood: .confused)
        }
        try? context.save()
    }

    private func reply(_ text: String, mood: MooneeMood, sources: [WebSource] = []) {
        let m = ChatMessage(fromUser: false, text: text)
        m.sources = sources
        post(m)
        self.mood = mood
        try? context.save()
    }

    private func openCamera() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true } else { showLibrary = true } // Simulator: no camera
    }

    private func startVoice() {
        focused = false
        text = ""
        Task { await speech.start() }
    }

    /// Tap again or let go: wait for the last words, then send them. Silence gets a friendly word, never nothing.
    private func endVoice() {
        let prompting = speech.isStarting // released while the permission prompts were up: no message
        Task {
            let heard = await speech.finish()
            guard !prompting, speech.failure == nil else { return }
            if heard.isEmpty { reply(ChatLines.heardNothing(), mood: .confused); return }
            inputSource = .voice
            send(heard)
        }
    }

    /// Receipt → OCR (Vision) → one expense, saved like a typed one.
    private func scan(_ image: UIImage) async {
        post(ChatMessage(fromUser: true, text: String(localized: "Receipt photo", table: "Chat")))
        busy = true
        let lines = (try? await ReceiptScanner.lines(in: image)) ?? []
        busy = false
        read(lines)
    }

    /// PDF receipt → its text (or OCR of its pages) → the same parser as a photo.
    private func scan(_ pdf: PDFDocument, name: String) async {
        post(ChatMessage(fromUser: true, text: name))
        busy = true
        let lines = await ChatBook.lines(in: pdf)
        busy = false
        read(lines)
    }

    private func read(_ lines: [String]) {
        if lines.isEmpty {
            reply(ChatLines.unreadableReceipt, mood: .confused)
        } else {
            record([ChatBook.receipt(lines, context: ParserContext(context))], source: .image, raw: lines.joined(separator: "\n"))
        }
    }
}
