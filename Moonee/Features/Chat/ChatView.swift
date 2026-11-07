import PhotosUI
import SwiftData
import SwiftUI

/// The Moonee chat (spec §3.1–3.3), opened by the (+) tab: type, say or snap a transaction, ask about money.
struct ChatView: View {
    var onBack: (() -> Void)? = nil
    /// Raised by the `moonee://chat` deep link: focus the composer.
    var composeRequest = 0

    @Environment(\.modelContext) private var context
    @Query(sort: \ChatMessage.date) private var allMessages: [ChatMessage]
    /// The conversation on screen; nil until the first message of the day.
    @State private var thread: ChatThread?
    /// Reopened from history: it keeps going even on a later day.
    @State private var resumed = false
    /// When `showToday` last ran: a later day replaces the open thread with today's.
    @State private var lastDayCheck = Date.now
    @Environment(\.scenePhase) private var scenePhase
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
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var libraryItems: [PhotosPickerItem] = []
    /// Photos and files waiting in the composer; they go with the next message.
    @State private var attachments: [ChatAttachment] = []
    @State private var savedCount = 0
    @State private var showReport = false
    @State private var suggestions: [ChatSuggestion] = []
    /// "Pick a date…" under "When will Nam pay you back?".
    @State private var pickingDue = false
    @State private var dueDay = Calendar.current.date(byAdding: .day, value: 7, to: .now)!
    /// The last `composeRequest` that focused the composer, so coming back to the tab does not raise the keyboard again.
    @State private var handledCompose = 0

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
                .onChange(of: messages.count, initial: true) { refreshSuggestions() }
                .onChange(of: busy) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            ChatComposer(text: $text, focus: $focused, isRecording: speech.isActive,
                         attachments: attachments, onRemoveAttachment: { id in attachments.removeAll { $0.id == id } },
                         onPlus: { showAdd = true }, onVoiceStart: startVoice, onVoiceEnd: endVoice, onCamera: openCamera,
                         onSend: { attachments.isEmpty ? send(text) : send(text, with: attachments) }, onChangeModel: { showAISettings = true })
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 10)
        }
        .background(MooneeBackground())
        .onAppear {
            ChatThreads.migrate(in: context)
            showToday()
            refreshSuggestions() // back from Budget after a split: the tiles follow
            // Opens as the idle pill (owner's reference): type, or hold the voice button to talk.
        }
        // The tab stays alive for days: back from the background or past midnight, a new day gets its own thread.
        .onChange(of: scenePhase) { _, phase in if phase == .active { showToday(); refreshSuggestions() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in showToday() }
        .task(id: composeRequest) {
            guard composeRequest != handledCompose else { return }
            handledCompose = composeRequest
            focused = true // the widget's quick add: straight to typing
        }
        .onChange(of: speech.transcript) { _, t in
            guard !t.isEmpty, speech.isRecording else { return }
            text = t
            inputSource = .voice
        }
        .onChange(of: speech.failure) { _, f in if let f { reply(ChatLines.voice(f), mood: .confused) } }
        .onChange(of: speech.fallbackLocale) { _, l in if let l { reply(ChatLines.voiceFallback(l), mood: .listening) } }
        .sheet(isPresented: $showAdd) {
            AddToChatSheet(attachments: $attachments, onUnreadable: { reply(ChatLines.unreadableFile, mood: .confused) })
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in attachments.append(ChatAttachment(content: .image(image))) }.ignoresSafeArea()
        }
        .photosPicker(isPresented: $showLibrary, selection: $libraryItems, matching: .images, preferredItemEncoding: .compatible)
        .onChange(of: libraryItems) { _, picked in
            guard !picked.isEmpty else { return }
            libraryItems = []
            Task {
                for item in picked {
                    if let a = await ChatAttachment.load(item) { attachments.append(a) } else { reply(ChatLines.unreadableFile, mood: .confused) }
                }
            }
        }
        .sheet(isPresented: $showHistory) {
            ChatHistoryView(onOpen: { t in (thread, resumed, pending) = (t, true, nil) },
                            onNew: newChat)
        }
        .sheet(isPresented: $showAISettings) { NavigationStack { AISettingsView() } }
        .sheet(item: $editTxn) { TxnEditForm(txn: $0) }
        .sheet(isPresented: $showReport) { ReportSheet() }
        .sheet(isPresented: $pickingDue) { duePicker }
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
            let files = m.attachments
            if !files.isEmpty { SentAttachments(items: files) }
            if !m.text.isEmpty || files.isEmpty { ChatBubble(.user, m.text, sent: true) }
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
                ForEach(txns.filter { $0.kind == .income }) { t in
                    IncomeSplitPrompt(txn: t) { editTxn = t }.padding(.leading, 20)
                }
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
        let naming = t.isManual && t.title.isEmpty && m.fromUser && !m.text.isEmpty // photos alone: the next words name it
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

    private func showToday() {
        let shown = ChatThreads.onScreen(open: thread, resumed: resumed, lastCheck: lastDayCheck, in: context)
        if shown.thread != thread { (pending, editingCard) = (nil, nil) }
        (thread, resumed, lastDayCheck) = (shown.thread, shown.resumed, .now)
    }

    private func newChat() {
        (thread, resumed, pending, editingCard) = (ChatThreads.start(in: context), true, nil, nil)
    }

    /// Wallets or jars to pick when Moonee asked where a transfer goes.
    private var choices: [String] {
        guard let p = pending else { return [] }
        let book = ChatBook.Lookup(context)
        return book.asking(p).map { book.choices($0, for: p) } ?? []
    }

    private var choiceChips: some View {
        let chips = ForEach(choices, id: \.self) { chip($0) }
        let rows = stride(from: 0, to: choices.count, by: 2).map { Array(choices[$0..<min($0 + 2, choices.count)]) }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chips }
            VStack(alignment: .leading, spacing: 8) { // two a row ("This weekend · End of month")
                ForEach(rows, id: \.self) { row in HStack(spacing: 8) { ForEach(row, id: \.self) { chip($0) } } }
            }
            VStack(alignment: .leading, spacing: 8) { chips }
        }
        .padding(.leading, 48)
    }

    private func chip(_ name: String) -> some View {
        QuickReplyChip(title: name, symbol: name == DebtBook.pickDateTitle ? "calendar" : nil) {
            if name == DebtBook.pickDateTitle { pickingDue = true } else { send(name) }
        }
    }

    /// Three questions picked from the books (`ChatSuggestion.pick`), refreshed after each message.
    private var tiles: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(suggestions) { s in
                QuickReplyChip(title: s.title, symbol: s.symbol, style: .tile) {
                    switch s.action {
                    case .ask: send(s.title)
                    case .openSplit: AppRoute.shared.tab = .budget // the Budget header's "Split now" (Moonee's plan, by %, one jar)
                    case .openReport: showReport = true
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func refreshSuggestions() {
        let books = StoreLedger(context)
        suggestions = ChatSuggestion.pick(facts: books.budgetFacts, debts: books.debtList, currency: books.currency)
    }

    // MARK: Actions

    private func send(_ raw: String) {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !busy else { return }
        if speech.isRecording { speech.stop() }
        let source = inputSource
        (text, inputSource, editingCard) = ("", .text, nil)
        let history = messages.suffix(10).map { LLMMessage(role: $0.fromUser ? .user : .assistant, text: $0.text.replacingOccurrences(of: Terms.footerLine, with: "")) }
        post(ChatMessage(fromUser: true, text: input))
        let parser = ParserContext(context)

        // An answer to Moonee's question ("45k", "Vietcombank") fills the waiting transaction;
        // an amount only counts when the message is not a new transaction of its own.
        if var p = pending, let field = ChatBook.Lookup(context).asking(p),
           field != .amount || QuickParser.parse(input, context: parser).count <= 1,
           ChatBook.fill(&p, field, from: input, context: parser) {
            pending = nil
            switch field {
            case .dueDate: saveDue(p)
            case .reimbursed:
                ChatBook.setReimbursed(p, in: context)
                reply(ChatLines.reimbursedSaved(p), mood: .happy)
            default: record([p], source: source, raw: input)
            }
            return
        }
        pending = nil
        // "đặt hạn mức ăn uống 3tr": a setting, not a transaction.
        if let done = ChatBook.setLimit(input, in: context) {
            reply(done, mood: .happy)
            return
        }

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
            case .answer(let answer, let skill, let sources):
                reply(answer + (Terms.needsFooter(skill: skill, question: input) ? Terms.footerLine : ""), mood: .happy, sources: sources)
            case .facts(let facts, let skill):
                if let t = ChatBook.factsText(facts) {
                    reply(t + (Terms.needsFooter(skill: skill, question: input) ? Terms.footerLine : ""), mood: .happy, sources: ChatBook.sources(facts))
                }
                else { reply(ChatLines.confused(), mood: .confused) }
            }
        }
    }

    /// Saves right away (spec §3.2) and shows the card; asks for what is missing instead of guessing.
    private func record(_ parsed: [ParsedTxn], source: TxSource, raw: String) {
        let saved = ChatBook.save(parsed, source: source, rawInput: raw, in: context)
        if !saved.isEmpty {
            let m = ChatMessage(fromUser: false, text: [ChatLines.saved(saved), ChatBook.debtLeft(saved, in: context)].compactMap { $0 }.joined(separator: " "))
            post(m)
            m.txns = saved
            mood = .happy
            savedCount += 1
            if let note = ChatBook.adviceAfter(saved, in: context) { reply(note, mood: .thinking) }
        }
        let book = ChatBook.Lookup(context)
        if let ask = parsed.first(where: { book.unresolved($0) != nil }), let field = book.unresolved(ask) {
            if [.toWallet, .jar, .toJar].contains(field), book.choices(field, for: ask).isEmpty {
                reply(ChatLines.oneWallet, mood: .confused)
            } else {
                pending = ask
                reply(ChatLines.question(field, ask), mood: .confused)
            }
        } else if let ask = ChatBook.dueQuestion(saved) { // a new loan: when is it due back? (spec §4.5)
            pending = ask
            reply(ChatLines.question(.dueDate, ask), mood: .happy)
        } else if let ask = ChatBook.reimburseQuestion(saved) { // paid for the boss: not my spending? (P1-2)
            pending = ask
            reply(ChatLines.question(.reimbursed, ask), mood: .thinking)
        } else if saved.isEmpty {
            reply(ChatLines.confused(), mood: .confused)
        }
        try? context.save()
    }

    private func saveDue(_ p: ParsedTxn) {
        ChatBook.setDue(p, in: context)
        reply(ChatLines.dueSaved(p), mood: .happy)
    }

    private var duePicker: some View {
        NavigationStack {
            DatePicker(String(localized: "Due date", table: "Chat"), selection: $dueDay, in: Calendar.current.startOfDay(for: .now)..., displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done", table: "Chat")) {
                            pickingDue = false
                            guard var p = pending else { return }
                            pending = nil
                            p.dueDate = Calendar.current.startOfDay(for: dueDay)
                            post(ChatMessage(fromUser: true, text: dueDay.formatted(.dateTime.day().month(.defaultDigits).year())))
                            saveDue(p)
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
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

    /// Text + photos / PDFs as one message (spec §3.1). Each is read as a document (`Assistant.readDocument`: a model
    /// when one is set up, else the rules): a receipt or bill is an expense, a transfer screenshot asks what it was,
    /// a statement gives several transactions, anything else nothing. The text says what it was
    /// (`ChatBook.transactions(_:context:described:)`); with no money in the photos, the text alone is read.
    private func send(_ raw: String, with files: [ChatAttachment]) {
        guard !busy else { return }
        if speech.isRecording { speech.stop() }
        let note = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        (text, inputSource, editingCard, pending, attachments) = ("", .text, nil, nil, [])
        let m = ChatMessage(fromUser: true, text: note)
        m.attachments = files.map(\.stored)
        post(m)
        busy = true
        let assistant = Assistant(router: LLMSettings.router(), tools: MooneeTools(ledger: StoreLedger(context)), catalog: SkillCatalog(context))
        let seesImages = assistant.router.candidates(for: .parse).contains { $0.acceptsImages }
        Task {
            let parser = ParserContext(context)
            var parsed: [ParsedTxn] = [], raws = [note], unread = 0, notMoney = 0
            for f in files {
                let lines = await f.lines()
                if lines.isEmpty { unread += 1; continue }
                let doc = await assistant.readDocument(lines, image: seesImages ? f.jpeg : nil, context: parser).read
                let txns = ChatBook.transactions(doc, context: parser, described: note)
                if txns.isEmpty { notMoney += 1; continue }
                parsed += txns
                raws.append(lines.map(\.text).joined(separator: "\n"))
            }
            if parsed.isEmpty, notMoney > 0, !note.isEmpty { // "grab về nhà 45k" with a photo that shows no money
                parsed = QuickParser.parse(note, context: parser)
                if !parsed.isEmpty { notMoney = 0 }
            }
            let (fresh, duplicates) = ChatBook.fresh(parsed, in: context)
            busy = false
            if !fresh.isEmpty { record(fresh, source: .image, raw: raws.filter { !$0.isEmpty }.joined(separator: "\n\n")) }
            if duplicates > 0 { reply(ChatLines.alreadyRecorded, mood: .happy) }
            if notMoney > 0 { reply(ChatLines.notMoney, mood: .confused) }
            if unread > 0 { reply(ChatLines.unreadableReceipt, mood: .confused) }
        }
    }
}
