import SwiftData
import SwiftUI

struct WalletsView: View {
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @State private var hidden = false
    @State private var editing: Wallet?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Tổng số dư").font(.subheadline)
                        Spacer()
                        Button { hidden.toggle() } label: {
                            Image(systemName: hidden ? "eye.slash" : "eye").padding(8).background(.white.opacity(0.2), in: .circle)
                        }
                    }
                    Text(hidden ? "••••••• đ" : wallets.reduce(0) { $0 + $1.balance }.vnd)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Spacer(minLength: 40)
                }
                .foregroundStyle(.white)
                .padding(20)
                .background(alignment: .bottom) { Hills().frame(height: 80) }
                .background(LinearGradient(colors: [.mooneeGreen, .mooneeDark], startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(.rect(cornerRadius: 24))
                .shadow(color: .mooneeGreen.opacity(0.3), radius: 14, y: 6)

                VStack(spacing: 0) {
                    ForEach(wallets) { w in
                        Button { editing = w } label: { WalletRow(wallet: w, hidden: hidden) }
                            .buttonStyle(.plain)
                        if w != wallets.last { Divider().padding(.leading, 52) }
                    }
                }
                .card(padding: 12)

                Button { adding = true } label: { Label("Thêm ví", systemImage: "plus") }
                    .font(.headline)
                    .foregroundStyle(Color.mooneeDark)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.mooneeGreen.opacity(0.12), in: .capsule)
            }
            .foregroundStyle(Color.mooneeInk)
            .mooneeScreen("Ví")
            .toolbar {
                Button("Thêm ví", systemImage: "plus") { adding = true }
            }
            .sheet(isPresented: $adding) { WalletForm(wallet: nil, nextOrder: wallets.count) }
            .sheet(item: $editing) { WalletForm(wallet: $0, nextOrder: wallets.count) }
        }
    }
}

private struct WalletRow: View {
    let wallet: Wallet
    let hidden: Bool

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: wallet.type.symbol, color: wallet.type.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(wallet.name).font(.subheadline.weight(.medium))
                if let limit = wallet.creditLimit {
                    Text("Hạn mức: \(limit.vnd)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(hidden ? "•••" : wallet.balance.vnd).font(.subheadline.weight(.semibold))
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .contentShape(.rect)
    }
}

private struct WalletForm: View {
    let wallet: Wallet?
    let nextOrder: Int
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type: WalletType = .cash
    @State private var initial = 0
    @State private var limit = 0
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Tên ví", text: $name)
                Picker("Loại", selection: $type) {
                    ForEach(WalletType.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                LabeledContent("Số dư ban đầu") {
                    TextField("0", value: $initial, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                if type == .credit {
                    LabeledContent("Hạn mức") {
                        TextField("0", value: $limit, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                }
                if wallet != nil {
                    Button("Xoá ví", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle(wallet == nil ? "Thêm ví" : "Sửa ví")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Lưu", action: save).disabled(name.isEmpty) }
            }
            .confirmationDialog("Xoá ví sẽ xoá luôn các giao dịch của ví này.", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Xoá ví", role: .destructive) {
                    if let wallet { context.delete(wallet) }
                    dismiss()
                }
            }
            .onAppear {
                guard let wallet else { return }
                name = wallet.name
                type = wallet.type
                initial = wallet.initialBalance
                limit = wallet.creditLimit ?? 0
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let w = wallet ?? Wallet(name: name, type: type, order: nextOrder)
        if wallet == nil { context.insert(w) }
        w.name = name
        w.type = type
        w.initialBalance = initial
        w.creditLimit = type == .credit && limit > 0 ? limit : nil
        dismiss()
    }
}
