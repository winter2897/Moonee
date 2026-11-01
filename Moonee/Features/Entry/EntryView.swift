import SwiftData
import SwiftUI

struct EntryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \Wallet.order) private var wallets: [Wallet]

    @State private var kind: TxKind = .expense
    @State private var digits = ""
    @State private var category: Category?
    @State private var wallet: Wallet?
    @State private var date = Date()
    @State private var note = ""
    @State private var savedTick = 0
    @FocusState private var focus: Field?

    private enum Field { case amount, note }
    private var amount: Int { Int(digits) ?? 0 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                PillPicker(options: TxKind.allCases.map { ($0, $0.title) }, selection: $kind)

                // Hidden field holds raw digits; the Text shows them grouped (avoids cursor jumps while reformatting).
                TextField("", text: $digits)
                    .keyboardType(.numberPad)
                    .focused($focus, equals: .amount)
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .frame(maxWidth: .infinity, minHeight: 70)
                    .overlay {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(amount == 0 ? "0" : amount.grouped).foregroundStyle(amount == 0 ? .secondary : Color.mooneeInk)
                            Text("đ").underline()
                        }
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                        .allowsHitTesting(false)
                    }
                .card(padding: 20)
                .onTapGesture { focus = .amount }
                .onChange(of: digits) { digits = String(digits.filter(\.isNumber).prefix(13)) }

                VStack(spacing: 10) {
                    Menu {
                        Button("Chưa phân loại") { category = nil }
                        ForEach(categories.filter { $0.kind == kind }) { c in
                            Button(c.name, systemImage: c.icon) { category = c }
                        }
                    } label: {
                        EntryRow(symbol: category?.icon ?? "questionmark", color: category?.color ?? .gray,
                                 title: category?.name ?? "Chưa phân loại (AI sẽ tự xếp)")
                    }

                    Menu {
                        ForEach(wallets) { w in
                            Button(w.name, systemImage: w.type.symbol) { wallet = w }
                        }
                    } label: {
                        EntryRow(symbol: (wallet ?? wallets.first)?.type.symbol ?? "wallet.bifold.fill",
                                 color: (wallet ?? wallets.first)?.type.color ?? .mooneeGreen,
                                 title: (wallet ?? wallets.first)?.name ?? "Chọn ví")
                    }

                    HStack(spacing: 12) {
                        IconBadge(symbol: "calendar", color: .mooneeDark)
                        DatePicker("Ngày", selection: $date, displayedComponents: .date)
                            .labelsHidden()
                            .environment(\.locale, Locale(identifier: "vi_VN"))
                        Spacer()
                    }
                    .card(padding: 12)

                    HStack(spacing: 12) {
                        IconBadge(symbol: "note.text", color: .mooneeDark)
                        TextField("Ghi chú (tuỳ chọn)", text: $note).focused($focus, equals: .note)
                    }
                    .card(padding: 12)
                }
                .foregroundStyle(Color.mooneeInk)

            }
            .mooneeScreen("Nhập giao dịch")
            .scrollDismissesKeyboard(.immediately)
            .safeAreaInset(edge: .bottom) {
                if focus == nil {
                    Button(action: save) { Label("Lưu giao dịch", systemImage: "checkmark") }
                        .buttonStyle(MooneeButtonStyle())
                        .padding(.horizontal, 40)
                        .padding(.bottom, 8)
                        .disabled(amount == 0)
                        .opacity(amount == 0 ? 0.5 : 1)
                }
            }
            .sensoryFeedback(.success, trigger: savedTick)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Xong") { focus = nil }
                }
            }
            .onChange(of: kind) { if category?.kind != kind { category = nil } }
        }
    }

    private func save() {
        guard amount > 0 else { return }
        context.insert(Txn(amount: amount, kind: kind, date: date, note: note,
                           category: category, wallet: wallet ?? wallets.first))
        digits = ""
        note = ""
        focus = nil
        savedTick += 1
    }
}

private struct EntryRow: View {
    let symbol: String
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: symbol, color: color)
            Text(title).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        }
        .card(padding: 12)
    }
}
