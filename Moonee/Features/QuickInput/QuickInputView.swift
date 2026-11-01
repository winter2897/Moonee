import PhotosUI
import SwiftData
import SwiftUI

/// Chat-style entry: type "cà phê 45k", say it, or snap a receipt. Category is optional; the AI accountant fills gaps later.
struct QuickInputView: View {
    @Environment(\.modelContext) private var context
    @Query(Self.recentDescriptor) private var recent: [Txn]
    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \Wallet.order) private var wallets: [Wallet]

    @State private var text = ""
    @State private var source: TxSource = .text
    @State private var hint: String?
    @State private var speech = SpeechInput()
    @State private var editing: Txn?
    @State private var editingIsNew = false
    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var photoItem: PhotosPickerItem?
    @State private var scanning = false
    @State private var sentTick = 0

    static var recentDescriptor: FetchDescriptor<Txn> {
        var d = FetchDescriptor<Txn>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        d.fetchLimit = 50
        return d
    }

    private var bubbles: [Txn] { recent.filter { $0.source != .bank }.reversed() }
    private var preview: ParsedEntry? { QuickParser.parse(text, categories: categories.map(\.name)) }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if bubbles.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.largeTitle).foregroundStyle(Color.mooneeGreen)
                        Text("Gõ như nhắn tin").font(.headline)
                        Text("\"cà phê 45k\" · \"ăn trưa 1tr2 hôm qua\"\n\"lương 15 triệu\" · \"grab 32.000đ\"")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .card(padding: 24)
                    .padding(.top, 40)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                ForEach(bubbles) { txn in
                    TxnBubble(txn: txn)
                        .contentShape(.rect)
                        .onTapGesture { editingIsNew = false; editing = txn }
                        .swipeActions { Button("Xoá", systemImage: "trash", role: .destructive) { context.delete(txn) }.tint(.red) }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .id(txn.persistentModelID)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(MooneeBackground())
            .onAppear { scrollToEnd(proxy) }
            .onChange(of: bubbles.last?.persistentModelID) { withAnimation { scrollToEnd(proxy) } }
        }
        .navigationTitle("Nhập giao dịch")
        .safeAreaInset(edge: .bottom) { inputBar }
        .sheet(item: $editing) { TxnEditor(txn: $0, isNew: editingIsNew) }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in Task { await scan(image) } }.ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) {
            guard let item = photoItem else { return }
            photoItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { await scan(image) }
            }
        }
        .onChange(of: speech.transcript) {
            guard speech.isRecording else { return }
            text = speech.transcript
            source = .voice
        }
        .sensoryFeedback(.success, trigger: sentTick)
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let p = preview {
                Label {
                    Text("\(p.kind == .expense ? "−" : "+")\(p.amount.vnd) · \(p.category ?? "Chưa phân loại") · \(p.date.chatDay)")
                } icon: { Image(systemName: "sparkles") }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(p.kind == .expense ? Color.mooneeInk : .mooneeDark)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.white.opacity(0.85), in: .capsule)
            } else if let msg = speech.error ?? hint ?? (scanning ? "Đang đọc hoá đơn…" : nil) {
                Text(msg).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 12)
            }

            HStack(spacing: 8) {
                Menu {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button("Chụp hoá đơn", systemImage: "camera") { showCamera = true }
                    }
                    Button("Chọn ảnh hoá đơn", systemImage: "photo") { showPhotos = true }
                } label: {
                    Group {
                        if scanning { ProgressView() } else { Image(systemName: "camera.fill") }
                    }
                    .frame(width: 40, height: 40)
                    .background(Color.mooneeGreen.opacity(0.15), in: .circle)
                }
                .disabled(scanning)

                TextField("Cà phê 45k, lương 15tr…", text: $text)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.vertical, 10)

                if speech.isRecording {
                    roundButton("stop.fill", color: .red) { speech.stop() }
                } else if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    roundButton("mic.fill", color: .mooneeGreen) { Task { await speech.start() } }
                } else {
                    roundButton("arrow.up", color: .mooneeGreen, action: send)
                }
            }
            .foregroundStyle(Color.mooneeDark)
            .padding(.leading, 6).padding(.trailing, 6)
            .background(.white, in: .capsule)
            .shadow(color: .mooneeDark.opacity(0.12), radius: 12, y: 4)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.snappy, value: preview)
    }

    private func roundButton(_ symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(color.gradient, in: .circle)
        }
    }

    private func send() {
        if speech.isRecording { speech.stop() }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p = QuickParser.parse(raw, categories: categories.map(\.name)) else {
            hint = raw.isEmpty ? nil : "Chưa thấy số tiền, thử \"cà phê 45k\""
            return
        }
        let category = categories.first { $0.name == p.category && $0.kind == p.kind }
        context.insert(Txn(amount: p.amount, kind: p.kind, date: p.date, note: p.note, source: source,
                           rawInput: raw, category: category, wallet: wallets.first))
        text = ""
        source = .text
        hint = nil
        sentTick += 1
    }

    private func scan(_ image: UIImage) async {
        scanning = true
        defer { scanning = false }
        let lines = (try? await ReceiptScanner.lines(in: image)) ?? []
        guard !lines.isEmpty else { hint = "Không đọc được chữ trên ảnh"; return }
        // Saved now so the editor can bind to it; "Huỷ" deletes it.
        let txn = Txn(amount: QuickParser.receiptTotal(lines) ?? 0, kind: .expense, note: lines[0], source: .photo,
                      rawInput: lines.joined(separator: "\n"), wallet: wallets.first)
        context.insert(txn)
        editingIsNew = true
        editing = txn
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = bubbles.last { proxy.scrollTo(last.persistentModelID, anchor: .bottom) }
    }
}

private struct TxnBubble: View {
    let txn: Txn

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(txn.source == .photo || txn.rawInput == nil ? txn.note : txn.rawInput!)
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(LinearGradient(colors: [.mooneeGreen, .mooneeDark], startPoint: .top, endPoint: .bottom),
                            in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20))

            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary)
                IconBadge(symbol: txn.category?.icon ?? "questionmark", color: txn.category?.color ?? .gray, size: 20)
                Text(txn.category?.name ?? "Chưa phân loại").foregroundStyle(.secondary)
                Text("· \(txn.date.chatDay) ·").foregroundStyle(.secondary)
                Text("\(txn.kind == .expense ? "−" : "+")\(txn.amount.vnd)")
                    .fontWeight(.semibold)
                    .foregroundStyle(txn.kind == .expense ? Color.mooneeInk : .mooneeDark)
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 40)
    }

    private var icon: String {
        switch txn.source {
        case .voice: "mic.fill"
        case .photo: "camera.fill"
        case .manual: "square.and.pencil"
        case .text, .bank: "text.bubble.fill"
        }
    }
}

/// Edit a saved txn in place, or confirm a new one (receipt scan) where "Huỷ" deletes it.
struct TxnEditor: View {
    @Bindable var txn: Txn
    let isNew: Bool
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.name) private var categories: [Category]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Số tiền", value: $txn.amount, format: .number.locale(Locale(identifier: "vi_VN")))
                        .keyboardType(.numberPad)
                        .font(.system(.title, design: .rounded, weight: .bold))
                    Picker("Loại", selection: $txn.kind) {
                        ForEach(TxKind.allCases, id: \.self) { Text($0.title) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Picker("Danh mục", selection: $txn.category) {
                        Text("Chưa phân loại").tag(Category?.none)
                        ForEach(categories.filter { $0.kind == txn.kind }) { Label($0.name, systemImage: $0.icon).tag(Category?.some($0)) }
                    }
                    DatePicker("Ngày", selection: $txn.date, displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "vi_VN"))
                    TextField("Ghi chú", text: $txn.note)
                }
                if let raw = txn.rawInput {
                    Section(txn.source == .photo ? "Chữ đọc từ ảnh" : "Bạn đã nhập") {
                        Text(raw).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !isNew {
                    Button("Xoá giao dịch", role: .destructive) { context.delete(txn); dismiss() }
                }
            }
            .navigationTitle(isNew ? "Xác nhận hoá đơn" : "Sửa giao dịch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isNew {
                    ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { context.delete(txn); dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Lưu" : "Xong") { dismiss() }.disabled(txn.amount <= 0)
                }
            }
            .interactiveDismissDisabled(isNew || txn.amount <= 0)
            .onChange(of: txn.kind) { if txn.category?.kind != txn.kind { txn.category = nil } }
        }
    }
}

extension Date {
    /// "Hôm nay", "Hôm qua", else "28/10".
    var chatDay: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Hôm nay" }
        if cal.isDateInYesterday(self) { return "Hôm qua" }
        return formatted(.dateTime.day().month(.twoDigits).locale(Locale(identifier: "vi_VN")))
    }
}
