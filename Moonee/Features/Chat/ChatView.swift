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
    @State private var lastNotice: String?
    @State private var mood = MooneeMood.greeting
    /// Parsed without an amount; Moonee asked "how much?" and the next message fills it in.
    @State private var pending: ParsedTxn?
    @State private var editingCard: PersistentIdentifier?
    @State private var editTxn: Txn?
    @State private var speech = SpeechInput()
    @State private var showAdd = false
    @State private var showHistory = false
    @State private var showAISettings = false
    @State private var savedCount = 0
    @State private var showReport = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
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
            ChatComposer(text: $text, focus: $focused, isRecording: speech.isRecording,
                         onPlus: { showAdd = true }, onMic: toggleMic, onHoldStart: startHold, onHoldEnd: endHold,
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
            guard !t.isEmpty else { return }
            text = t
            inputSource = .voice
        }
        .onChange(of: speech.error) { _, e in if let e { reply(e, mood: .confused) } }
        .sheet(isPresented: $showAdd) {
            AddToChatSheet { image in Task { await scan(image) } }
                .presentationDetents([.medium, .large])
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

    private var header: some View {
        VStack(spacing: 0) {
            MooneeHeader(Text("Your finance assistant", tableName: "Chat")) {
                if let onBack {
                    Button(action: onBack) { HeaderCircle("chevron.left") }.accessibilityLabel(Text("Back", tableName: "Chat"))
                }
            } trailing: {
                Button { showHistory = true } label: { HeaderCircle("clock.arrow.circlepath") }
                    .accessibilityLabel(Text("Chat history", tableName: "Chat"))
            }
            .padding(.horizontal, 16)

            // 76 pt while typing so the keyboard leaves room for the chat (UI review C-1).
            MooneeHero(mood: currentMood, compact: focused)
                .padding(.horizontal, 16)
                .animation(.smooth, value: focused)
                .animation(.smooth, value: currentMood)
        }
    }

    // MARK: Messages

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChatBubble(.moonee, String(localized: "**Hi there!** 👋\nWhat can Moonee do for you today? Log a spend, ask about your money, or snap a receipt.", table: "Chat"))
            // One row when the three fit (mockup), else the third wraps: never cut off at the edge (UI review C-3).
            let say = QuickReplyChip(title: String(localized: "Say a spend", table: "Chat"), symbol: "mic", action: toggleMic)
            let scan = QuickReplyChip(title: String(localized: "Scan a receipt", table: "Chat"), symbol: "camera") { showAdd = true }
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
        context.insert(m)
        ChatThreads.add(m, to: t)
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
            let r = await assistant.reply(input, history: history, context: parser)
            let out = r.output
            withAnimation { busy = false }
            // Why the chosen model didn't answer (Apple Intelligence off, too long…), once until it changes.
            if let notice = r.noticeText, notice != lastNotice { lastNotice = notice; reply(notice, mood: .confused) }
            switch out {
            case .transactions(let txns, _): record(txns, source: source, raw: input)
            case .answer(let answer, _, let sources): reply(answer, mood: .happy, sources: sources)
            case .facts(let facts, _):
                if let t = ChatBook.factsText(facts) { reply(t, mood: .happy, sources: ChatBook.sources(facts)) }
                else { reply(Self.confused, mood: .confused) }
            }
        }
    }

    /// Saves right away (spec §3.2) and shows the card; asks for what is missing instead of guessing.
    private func record(_ parsed: [ParsedTxn], source: TxSource, raw: String) {
        let saved = ChatBook.save(parsed, source: source, rawInput: raw, in: context)
        if !saved.isEmpty {
            let m = ChatMessage(fromUser: false, text: String(localized: "Got it! Moonee logged \(saved.count) transactions for you:", table: "Chat"))
            post(m)
            m.txns = saved
            mood = .happy
            savedCount += 1
        }
        let book = ChatBook.Lookup(context)
        if let ask = parsed.first(where: { book.unresolved($0) != nil }), let field = book.unresolved(ask) {
            if [.toWallet, .jar, .toJar].contains(field), book.choices(field, for: ask).isEmpty {
                reply(String(localized: "You only have one wallet so far. Add another in Budget, then tell Moonee again.", table: "Chat"), mood: .confused)
            } else {
                pending = ask
                reply(Self.question(field, ask), mood: .confused)
            }
        } else if saved.isEmpty {
            reply(Self.confused, mood: .confused)
        }
        try? context.save()
    }

    private static func question(_ field: ParsedTxn.Field, _ p: ParsedTxn) -> String {
        switch field {
        case .toWallet: return String(localized: "Which wallet did the money go to?", table: "Chat")
        case .jar: return String(localized: "Which jar should Moonee take it from?", table: "Chat")
        case .toJar: return String(localized: "Which jar should it go into?", table: "Chat")
        case .amount, .person:
            let what = p.note.trimmingCharacters(in: .whitespaces)
            return what.isEmpty ? String(localized: "How much was it? Tell Moonee the amount, e.g. 45k.", table: "Chat")
                                : String(localized: "How much was **\(what)**? Tell Moonee the amount, e.g. 45k.", table: "Chat")
        }
    }

    private func reply(_ text: String, mood: MooneeMood, sources: [WebSource] = []) {
        let m = ChatMessage(fromUser: false, text: text)
        m.sources = sources
        post(m)
        self.mood = mood
        try? context.save()
    }

    private static var confused: String {
        String(localized: "Hmm, Moonee didn't quite get that 🤔 Try something like “phở 45k” or “how much did I spend this month?”", table: "Chat")
    }

    private func toggleMic() {
        if speech.isRecording {
            speech.stop()
            focused = true
        } else {
            focused = false
            Task { await speech.start() }
        }
    }

    /// Hold to talk: dictate while held, send on release.
    private func startHold() {
        guard !speech.isRecording else { return }
        focused = false
        text = ""
        Task { await speech.start() }
    }

    // ponytail: the recognizer delivers its final words a moment after the audio stops; 0.6 s covers it on device.
    private func endHold() {
        speech.stop()
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            send(text)
        }
    }

    /// Receipt → OCR (Vision) → one expense, saved like a typed one.
    private func scan(_ image: UIImage) async {
        busy = true
        let lines = (try? await ReceiptScanner.lines(in: image)) ?? []
        busy = false
        post(ChatMessage(fromUser: true, text: String(localized: "📷 Receipt", table: "Chat")))
        if lines.isEmpty {
            reply(String(localized: "Moonee couldn't read that photo 😵 Try again with the whole receipt in good light.", table: "Chat"), mood: .confused)
        } else {
            record([ChatBook.receipt(lines, context: ParserContext(context))], source: .image, raw: lines.joined(separator: "\n"))
        }
    }
}
