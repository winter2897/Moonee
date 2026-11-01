import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct BankLinkView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @Bindable private var sync = BankSync.shared
    @State private var token = ""
    @State private var linking = false
    @State private var linkError: String?
    @State private var importing = false
    @State private var importError: String?
    @State private var statement: ImportedStatement?
    @State private var confirmUnlink = false

    var body: some View {
        VStack(spacing: 14) {
            if sync.isLinked {
                statusCard
                if !sync.state.accounts.isEmpty { accountsCard }
            } else {
                linkCard
            }
            csvCard
            if sync.isLinked {
                Button("Huỷ liên kết SePay", role: .destructive) { confirmUnlink = true }
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
            }
        }
        .foregroundStyle(Color.mooneeInk)
        .mooneeScreen("Liên kết ngân hàng")
        .refreshable { await sync.sync(context, force: true) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText], onCompletion: open)
        .sheet(item: $statement) { StatementImportView(statement: $0) }
        .alert("Không đọc được file", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
        .confirmationDialog("Giao dịch đã nhập vẫn được giữ lại.", isPresented: $confirmUnlink, titleVisibility: .visible) {
            Button("Huỷ liên kết", role: .destructive) { sync.unlink() }
        }
    }

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(symbol: "building.columns.fill", color: WalletType.bank.color)
                Text("Kết nối qua SePay").font(.headline)
            }
            Text("1. Đăng ký [my.sepay.vn](https://my.sepay.vn) và liên kết tài khoản ngân hàng (gói Free: 50 giao dịch/tháng).\n2. Vào Cấu hình công ty → API Access → Thêm API, sao chép token.\n3. Dán token vào đây.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .tint(.mooneeDark)
            SecureField("API token", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(Color.mooneeGreen.opacity(0.08), in: .rect(cornerRadius: 14))
            if let linkError {
                Label(linkError, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            }
            Button(action: link) {
                if linking { ProgressView().tint(.white) } else { Label("Kết nối", systemImage: "link") }
            }
            .buttonStyle(MooneeButtonStyle())
            .disabled(token.isEmpty || linking)
            Label("Token chỉ lưu trong Keychain của máy. SePay đọc biến động số dư thay bạn nên cũng thấy lịch sử giao dịch.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(symbol: "arrow.triangle.2.circlepath", color: .mooneeGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Đã liên kết SePay").font(.headline)
                    Group {
                        if let last = sync.state.lastSync {
                            Text("Đồng bộ lúc \(last.formatted(.dateTime.hour().minute().day().month().locale(Locale(identifier: "vi_VN")))) · \(sync.state.lastImported) giao dịch mới")
                        } else {
                            Text("Chưa đồng bộ")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if sync.isSyncing { ProgressView() }
            }
            if let error = sync.state.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            }
            Button { Task { await sync.sync(context, force: true) } } label: {
                Label("Đồng bộ ngay", systemImage: "arrow.clockwise")
            }
            .buttonStyle(MooneeButtonStyle())
            .disabled(sync.isSyncing)
        }
        .card()
    }

    private var accountsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tài khoản → Ví").font(.subheadline.weight(.semibold)).padding(.bottom, 6)
            ForEach($sync.state.accounts) { $account in
                HStack(spacing: 12) {
                    IconBadge(symbol: WalletType.bank.symbol, color: WalletType.bank.color, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.bank).font(.subheadline.weight(.medium))
                        Text("••\(account.number.suffix(4))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Ví", selection: $account.walletID) {
                        Text("Tạo ví mới").tag(PersistentIdentifier?.none)
                        ForEach(wallets.filter { $0.type == .bank }) { Text($0.name).tag(Optional($0.persistentModelID)) }
                    }
                    .labelsHidden()
                    .tint(.mooneeDark)
                }
                .padding(.vertical, 8)
                if account != sync.state.accounts.last { Divider().padding(.leading, 46) }
            }
        }
        .card(padding: 14)
    }

    private var csvCard: some View {
        Button { importing = true } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: "doc.text.fill", color: Color(hex: 0xF59E0B))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nhập sao kê CSV").font(.subheadline.weight(.medium))
                    Text("Xuất sao kê từ app ngân hàng; file Excel hãy lưu thành CSV.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .card(padding: 14)
    }

    private func link() {
        linking = true
        linkError = nil
        Task {
            do {
                try await sync.link(token: token.trimmingCharacters(in: .whitespacesAndNewlines), context: context)
                token = ""
            } catch {
                linkError = error.localizedDescription
            }
            linking = false
        }
    }

    private func open(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(decoding: data, as: UTF8.self)
            let csv = StatementCSV(text)
            guard !csv.rows.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            statement = ImportedStatement(name: url.lastPathComponent, csv: csv)
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct ImportedStatement: Identifiable {
    let id = UUID()
    let name: String
    let csv: StatementCSV
}

private struct StatementImportView: View {
    let statement: ImportedStatement
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @State private var mapping: StatementCSV.Mapping
    @State private var walletID: PersistentIdentifier?
    @State private var result: String?

    init(statement: ImportedStatement) {
        self.statement = statement
        _mapping = State(initialValue: statement.csv.detected)
    }

    var body: some View {
        let drafts = statement.csv.drafts(mapping)
        NavigationStack {
            Form {
                Picker("Nhập vào ví", selection: $walletID) {
                    ForEach(wallets) { Text($0.name).tag(Optional($0.persistentModelID)) }
                }
                Section {
                    column("Ngày", $mapping.date)
                    column("Nội dung", $mapping.memo)
                    column("Số tiền (±)", $mapping.amount)
                    column("Ghi nợ (chi)", $mapping.debit)
                    column("Ghi có (thu)", $mapping.credit)
                    column("Mã tham chiếu", $mapping.reference)
                } header: { Text("Cột") } footer: {
                    Text("Dùng một cột Số tiền (âm là chi) hoặc hai cột Ghi nợ/Ghi có. Mã tham chiếu giúp bỏ qua giao dịch đã nhập.")
                }
                Section("Xem trước · \(drafts.count) giao dịch") {
                    ForEach(drafts.prefix(5), id: \.externalID) { d in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.memo.isEmpty ? "—" : d.memo).font(.subheadline).lineLimit(1)
                                Text(d.date.formatted(date: .numeric, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text((d.kind == .expense ? "-" : "+") + d.amount.vnd)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(d.kind == .expense ? Color.mooneeInk : .mooneeDark)
                        }
                    }
                }
            }
            .navigationTitle(statement.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Nhập") { save(drafts) }.disabled(drafts.isEmpty || walletID == nil)
                }
            }
            .alert(result ?? "", isPresented: .constant(result != nil)) {
                Button("OK") { dismiss() }
            }
            .onAppear {
                walletID = walletID ?? (wallets.first { $0.type == .bank } ?? wallets.first)?.persistentModelID
            }
        }
    }

    private func column(_ title: String, _ selection: Binding<Int?>) -> some View {
        Picker(title, selection: selection) {
            Text("—").tag(Int?.none)
            ForEach(statement.csv.header.indices, id: \.self) { i in
                Text(statement.csv.header[i].isEmpty ? "Cột \(i + 1)" : statement.csv.header[i]).tag(Optional(i))
            }
        }
    }

    private func save(_ drafts: [BankDraft]) {
        guard let wallet = wallets.first(where: { $0.persistentModelID == walletID }) else { return }
        do {
            let n = try BankImporter.insert(drafts, into: context) { _ in wallet }
            result = "Đã nhập \(n) giao dịch" + (n < drafts.count ? ", bỏ qua \(drafts.count - n) đã có." : ".")
        } catch {
            result = error.localizedDescription
        }
    }
}
