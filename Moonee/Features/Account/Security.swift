import LocalAuthentication
import SwiftUI

extension Prefs {
    /// Bool. Ask for Face ID / passcode on launch and on return (spec §6.4).
    static let appLock = "security.appLock"
    /// Int minutes in the background before the lock comes back; 0 = every time.
    static let lockAfterMinutes = "security.lockAfterMinutes"
    /// Bool, default true. Cover the screen in the App Switcher.
    static let privacyCover = "security.privacyCover"
}

enum AppLock {
    static func shouldLock(enabled: Bool, backgroundedAt: Date?, now: Date = .now, afterMinutes: Int) -> Bool {
        guard enabled, let backgroundedAt else { return false }
        return now.timeIntervalSince(backgroundedAt) >= Double(afterMinutes * 60)
    }

    /// Face ID / Touch ID with the device passcode as fallback. Nil error = unlocked.
    static func authenticate(reason: String) async -> String? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return error?.localizedDescription ?? String(localized: "Set a passcode on this iPhone first.", table: "Account")
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? nil : ""
        } catch {
            return error.localizedDescription
        }
    }

    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return switch context.biometryType {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        default: String(localized: "Passcode", table: "Account")
        }
    }
}

extension View {
    /// App lock + App Switcher cover for the whole app. Apply once on the root view.
    func appLock() -> some View { modifier(AppLockModifier()) }
}

private struct AppLockModifier: ViewModifier {
    @Environment(\.scenePhase) private var phase
    @AppStorage(Prefs.appLock) private var lockEnabled = false
    @AppStorage(Prefs.lockAfterMinutes) private var lockAfter = 0
    @AppStorage(Prefs.privacyCover) private var cover = true
    @State private var locked = UserDefaults.standard.bool(forKey: Prefs.appLock)
    @State private var backgroundedAt: Date?
    @State private var authenticating = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if locked {
                    LockScreen(unlock: unlock)
                } else if cover && phase != .active {
                    PrivacyCover()
                }
            }
            // The Face ID sheet only makes the scene inactive, so recording .background avoids a lock loop.
            .onChange(of: phase) { _, new in
                switch new {
                case .background: if backgroundedAt == nil { backgroundedAt = .now }
                case .active:
                    if AppLock.shouldLock(enabled: lockEnabled, backgroundedAt: backgroundedAt, afterMinutes: lockAfter) { locked = true }
                    backgroundedAt = nil
                    if locked { unlock() }
                default: break
                }
            }
            .onChange(of: lockEnabled) { if !lockEnabled { locked = false } }
            .task { if locked { unlock() } }
    }

    private func unlock() {
        guard !authenticating else { return }
        authenticating = true
        Task {
            if await AppLock.authenticate(reason: String(localized: "Unlock Moonee", table: "Account")) == nil { locked = false }
            authenticating = false
        }
    }
}

private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            MooneeBackground()
            Image("Logo").resizable().frame(width: 96, height: 96).clipShape(.rect(cornerRadius: 24))
        }
    }
}

private struct LockScreen: View {
    let unlock: () -> Void

    var body: some View {
        ZStack {
            MooneeBackground()
            VStack(spacing: 20) {
                MooneeCharacter(mood: .sleepy).frame(height: 180)
                Text("Moonee is locked", tableName: "Account").font(.title2.bold()).foregroundStyle(Color.ink)
                Button(action: unlock) {
                    Label { Text("Unlock with \(AppLock.biometryName)", tableName: "Account") } icon: { Image(systemName: "faceid") }
                }
                .buttonStyle(MooneeButtonStyle())
                .padding(.horizontal, 48)
            }
        }
    }
}

/// Account → Security & privacy (spec §6.4).
struct SecurityView: View {
    @AppStorage(Prefs.appLock) private var lockEnabled = false
    @AppStorage(Prefs.lockAfterMinutes) private var lockAfter = 0
    @AppStorage(Prefs.hideBalances) private var hideBalances = false
    @AppStorage(Prefs.privacyCover) private var cover = true
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { lockEnabled }, set: setLock)) {
                    Label { Text("Lock with \(AppLock.biometryName)", tableName: "Account") } icon: { Image(systemName: "faceid") }
                }
                if lockEnabled {
                    Picker(selection: $lockAfter) {
                        Text("Immediately", tableName: "Account").tag(0)
                        ForEach([1, 5, 15, 60], id: \.self) { m in
                            Text(Duration.seconds(m * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))).tag(m)
                        }
                    } label: {
                        Label { Text("Lock after", tableName: "Account") } icon: { Image(systemName: "timer") }
                    }
                }
            } footer: {
                if let error { Text(error).foregroundStyle(Color.danger) }
                else { Text("Asks when Moonee opens and when you come back after this long.", tableName: "Account") }
            }

            Section {
                Toggle(isOn: $hideBalances) {
                    Label { Text("Hide balances", tableName: "Account") } icon: { Image(systemName: "eye.slash") }
                }
                Toggle(isOn: $cover) {
                    Label { Text("Hide content in App Switcher", tableName: "Account") } icon: { Image(systemName: "rectangle.on.rectangle.slash") }
                }
            } footer: {
                Text("Hidden amounts show as •••••.", tableName: "Account")
            }

            Section {
                NavigationLink {
                    DataView()
                } label: {
                    Label { Text("Delete all data", tableName: "Account") } icon: { Image(systemName: "trash") }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .navigationTitle(Text("Security & privacy", tableName: "Account"))
    }

    /// Turning the lock on asks once, so nobody locks themselves out on a phone without a passcode.
    private func setLock(_ on: Bool) {
        error = nil
        guard on else { lockEnabled = false; return }
        Task {
            if let failure = await AppLock.authenticate(reason: String(localized: "Turn on the app lock", table: "Account")) {
                error = failure.isEmpty ? nil : failure
            } else {
                lockEnabled = true
            }
        }
    }
}
