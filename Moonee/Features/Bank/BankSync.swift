import BackgroundTasks
import Foundation
import Security
import SwiftData
import SwiftUI

/// One statement line from SePay or a CSV file, before it becomes a `Txn`.
struct BankDraft: Equatable {
    var externalID: String
    var account: String
    var bank: String
    var amount: Int
    var kind: TxKind
    var date: Date
    var memo: String
}

@MainActor enum BankImporter {
    /// Inserts drafts whose `externalID` isn't stored yet, leaving the category for the AI accountant.
    /// Returns how many were inserted.
    static func insert(_ drafts: [BankDraft], into context: ModelContext, wallet: (BankDraft) -> Wallet) throws -> Int {
        // ponytail: loads every imported id; fine for a personal ledger, use a #Predicate lookup past ~100k rows
        let imported = try context.fetch(FetchDescriptor<Txn>(predicate: #Predicate { $0.externalID != nil }))
        var seen = Set(imported.compactMap(\.externalID))
        var count = 0
        for d in drafts where seen.insert(d.externalID).inserted {
            let t = Txn(amount: d.amount, kind: d.kind, date: d.date, note: d.memo, source: .bank, rawInput: d.memo)
            t.externalID = d.externalID
            context.insert(t)
            t.wallet = wallet(d)
            count += 1
        }
        try context.save()
        return count
    }
}

enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// nil deletes. Readable after first unlock so background refresh can use it.
    static func set(_ value: String?, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value else { return }
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// SePay link state and the sync loop. The token lives in Keychain; the rest (account → wallet map,
/// last sync) is not secret and lives in UserDefaults.
@MainActor @Observable final class BankSync {
    static let shared = BankSync()
    static let tokenKey = "sepay.token"
    static let taskID = "com.haiquan.moonee.banksync"

    struct LinkedAccount: Codable, Hashable, Identifiable {
        var number: String
        var bank: String
        var walletID: PersistentIdentifier?
        var id: String { number }
    }

    struct State: Codable {
        var accounts: [LinkedAccount] = []
        var lastSync: Date?
        var lastImported = 0
        var lastError: String?
    }

    var state: State {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: "bankSync") }
    }
    var isLinked: Bool
    var isSyncing = false

    private init() {
        state = UserDefaults.standard.data(forKey: "bankSync").flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        isLinked = Keychain.get(Self.tokenKey) != nil
    }

    /// Validates the token by listing the user's bank accounts, then stores it and syncs.
    func link(token: String, context: ModelContext) async throws {
        let accounts = try await SePayClient(token: token).accounts()
        Keychain.set(token, for: Self.tokenKey)
        isLinked = true
        for a in accounts where !state.accounts.contains(where: { $0.number == a.accountNumber }) {
            let bank = a.bankShortName ?? a.label ?? "Ngân hàng"
            let existing = Self.existingWallet(named: Self.walletName(bank, a.accountNumber), in: context)
            state.accounts.append(LinkedAccount(number: a.accountNumber, bank: bank, walletID: existing?.persistentModelID))
        }
        await sync(context, force: true)
    }

    /// Imported transactions stay; only the token and mapping go.
    func unlink() {
        Keychain.set(nil, for: Self.tokenKey)
        isLinked = false
        state = State()
    }

    func sync(_ context: ModelContext, force: Bool = false) async {
        guard isLinked, !isSyncing, let token = Keychain.get(Self.tokenKey) else { return }
        if !force, let last = state.lastSync, Date.now.timeIntervalSince(last) < 300 { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            // ponytail: re-read a 1-day overlap (dedupe absorbs repeats); switch to since_id if banks post later than that
            let since = (state.lastSync ?? .now.addingTimeInterval(-30 * 86400)).addingTimeInterval(-86400)
            let drafts = try await SePayClient(token: token).transactions(since: since).compactMap(\.draft)
            state.lastImported = try BankImporter.insert(drafts, into: context) { wallet(for: $0, in: context) }
            state.lastSync = .now
            state.lastError = nil
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            state.lastError = error.localizedDescription
        }
    }

    /// The wallet mapped to the draft's account, else one an earlier link created, else a new `.bank` wallet.
    private func wallet(for d: BankDraft, in context: ModelContext) -> Wallet {
        if let id = state.accounts.first(where: { $0.number == d.account })?.walletID,
           let w = try? context.fetch(FetchDescriptor<Wallet>(predicate: #Predicate { $0.persistentModelID == id })).first {
            return w
        }
        let bank = state.accounts.first(where: { $0.number == d.account })?.bank ?? d.bank
        let name = Self.walletName(bank, d.account)
        let w = Self.existingWallet(named: name, in: context) ?? {
            let w = Wallet(name: name, type: .bank, order: (try? context.fetchCount(FetchDescriptor<Wallet>())) ?? 0)
            context.insert(w)
            try? context.save() // permanent id before we remember it
            return w
        }()
        if let i = state.accounts.firstIndex(where: { $0.number == d.account }) {
            state.accounts[i].walletID = w.persistentModelID
        } else {
            state.accounts.append(LinkedAccount(number: d.account, bank: bank, walletID: w.persistentModelID))
        }
        return w
    }

    private static func walletName(_ bank: String, _ number: String) -> String { "\(bank) ••\(number.suffix(4))" }

    /// Re-linking adopts the wallet an earlier link created instead of making a duplicate.
    private static func existingWallet(named name: String, in context: ModelContext) -> Wallet? {
        (try? context.fetch(FetchDescriptor<Wallet>(predicate: #Predicate { $0.name == name })))?.first { $0.type == .bank }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = .now.addingTimeInterval(3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func backgroundRefresh(_ container: ModelContainer) async {
        scheduleRefresh()
        await shared.sync(container.mainContext, force: true)
    }
}

/// Syncs when the app becomes active and schedules a background refresh when it leaves.
struct BankAutoSync: ViewModifier {
    @Environment(\.scenePhase) private var phase
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content.onChange(of: phase, initial: true) { _, phase in
            switch phase {
            case .active: Task { await BankSync.shared.sync(context) }
            case .background: if BankSync.shared.isLinked { BankSync.scheduleRefresh() }
            default: break
            }
        }
    }
}
