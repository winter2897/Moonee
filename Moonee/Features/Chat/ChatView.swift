import PhotosUI
import SwiftData
import SwiftUI

/// The Moonee chat (spec §3.1–3.3), opened by the (+) tab: type, say or snap a transaction, ask about money.
struct ChatView: View {
    var onBack: (() -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Query(sort: \ChatMessage.date) private var messages: [ChatMessage]
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
    @State private var photoItem: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var confirmClear = false
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
                        } else if let last = messages.last, !last.fromUser {
                            tiles
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                // The keyboard opens with the tab (spec §1) but always gets out of the way:
                // drag the chat (it bounces even when short) or tap outside a control.
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
            ChatInputBar(text: $text, isRecording: speech.isRecording, focus: $focused,
                         onPhoto: { choosingPhoto = true }, onMic: toggleMic, onSend: { send(text) })
                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
        }
        .background(MooneeBackground())
        .onAppear { focused = true }
        .onChange(of: speech.transcript) { _, t in
            guard !t.isEmpty else { return }
            text = t
            inputSource = .voice
        }
        .onChange(of: speech.error) { _, e in if let e { reply(e, mood: .confused) } }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { await scan(image) } }
        }
        .confirmationDialog(Text("Add a photo", tableName: "Chat"), isPresented: $choosingPhoto) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Text("Take a photo", tableName: "Chat") }
            }
            Button { showLibrary = true } label: { Text("Choose from library", tableName: "Chat") }
        }
        .photosPicker(isPresented: $showLibrary, selection: $photoItem, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in Task { await scan(image) } }.ignoresSafeArea()
        }
        .sheet(item: $editTxn) { TxnEditSheet(txn: $0) }
        .sheet(isPresented: $showReport) { ReportSheet() }
        .confirmationDialog(Text("Clear the chat? Your transactions stay in the ledger.", tableName: "Chat"),
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button(role: .destructive) { messages.forEach(context.delete) } label: { Text("Clear chat", tableName: "Chat") }
        }
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
                Menu {
                    Button(role: .destructive) { confirmClear = true } label: {
                        Label { Text("Clear chat", tableName: "Chat") } icon: { Image(systemName: "trash") }
                    }
                } label: { HeaderCircle("ellipsis") }
                .accessibilityLabel(Text("More", tableName: "Chat"))
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
            let scan = QuickReplyChip(title: String(localized: "Scan a receipt", table: "Chat"), symbol: "camera") { choosingPhoto = true }
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
        context.insert(ChatMessage(fromUser: true, text: input))
        let parser = ParserContext(context)

        // Answer to "how much?": a lone amount fills the waiting transaction.
        if var p = pending, let a = QuickParser.amount(in: input, context: parser), QuickParser.parse(input, context: parser).count <= 1 {
            pending = nil
            (p.amount, p.currency) = (a.amount, a.currency)
            record([p], source: source, raw: input)
            return
        }
        pending = nil

        busy = true
        let assistant = Assistant(router: LLMSettings.router(), tools: MooneeTools(ledger: StoreLedger(context)))
        Task {
            let out = await assistant.handle(input, history: history, context: parser)
            withAnimation { busy = false }
            switch out {
            case .transactions(let txns, _): record(txns, source: source, raw: input)
            case .answer(let answer, _): reply(answer, mood: .happy)
            case .facts(let facts, _):
                if let t = ChatBook.factsText(facts) { reply(t, mood: .happy) } else { reply(Self.confused, mood: .confused) }
            }
        }
    }

    /// Saves right away (spec §3.2) and shows the card; asks for a missing amount instead of guessing.
    private func record(_ parsed: [ParsedTxn], source: TxSource, raw: String) {
        let saved = ChatBook.save(parsed, source: source, rawInput: raw, in: context)
        if !saved.isEmpty {
            let m = ChatMessage(fromUser: false, text: String(localized: "Got it! Moonee logged \(saved.count) transactions for you:", table: "Chat"))
            context.insert(m)
            m.txns = saved
            mood = .happy
            savedCount += 1
        }
        if let ask = parsed.first(where: { $0.amount == nil }) {
            pending = ask
            let what = ask.note.trimmingCharacters(in: .whitespaces)
            reply(what.isEmpty ? String(localized: "How much was it? Tell Moonee the amount, e.g. 45k.", table: "Chat")
                               : String(localized: "How much was **\(what)**? Tell Moonee the amount, e.g. 45k.", table: "Chat"),
                  mood: .confused)
        } else if saved.isEmpty {
            reply(Self.confused, mood: .confused)
        }
        try? context.save()
    }

    private func reply(_ text: String, mood: MooneeMood) {
        context.insert(ChatMessage(fromUser: false, text: text))
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

    /// Receipt → OCR (Vision) → one expense, saved like a typed one.
    private func scan(_ image: UIImage) async {
        busy = true
        let lines = (try? await ReceiptScanner.lines(in: image)) ?? []
        busy = false
        context.insert(ChatMessage(fromUser: true, text: String(localized: "📷 Receipt", table: "Chat")))
        if lines.isEmpty {
            reply(String(localized: "Moonee couldn't read that photo 😵 Try again with the whole receipt in good light.", table: "Chat"), mood: .confused)
        } else {
            record([ChatBook.receipt(lines, context: ParserContext(context))], source: .image, raw: lines.joined(separator: "\n"))
        }
    }
}
