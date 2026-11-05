import StoreKit
import SwiftUI

/// Account tab (spec §6), laid out like the Account mockup minus the Pro card (the app is paid upfront).
struct AccountView: View {
    @AppStorage(Prefs.profileName) private var name = ""
    @AppStorage(Prefs.profileAvatar) private var avatar = ""
    @AppStorage(LLMSettings.modeKey) private var aiMode = LLMSettings.mode
    @AppStorage(Prefs.reminderLevel) private var reminderLevel = "medium"
    @AppStorage(Money.currencyKey) private var currency: String? // re-renders the row on change

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    NavigationLink { ProfileEditView() } label: { profileCard }.buttonStyle(.plain)

                    section("App settings") {
                        VStack(spacing: 0) {
                            AccountRow(symbol: "sparkles", title: "AI assistant", subtitle: "Mode, model and skills", badge: aiMode.badge) { AISettingsView() }
                            AccountRow(symbol: "slider.horizontal.3", title: "Reminders & notifications", subtitle: "Reminder level, times, kinds",
                                       badge: reminderBadge) { ReminderSettingsView() }
                            AccountRow(symbol: "checkmark.shield", title: "Security & privacy", subtitle: "Face ID, hide balances, delete data") { SecurityView() }
                            AccountRow(symbol: "globe", title: "Language & currency",
                                       subtitle: "\(AppLanguage.current) · \(Money.label(Money.defaultCurrency))") { LanguageCurrencyView() }
                            AccountRow(symbol: "cylinder.split.1x2", title: "Data", subtitle: "iCloud, CSV export, delete all") { DataView() }
                            AccountRow(symbol: "square.stack.3d.up", title: "Categories, jars & wallets", subtitle: "Set up your budget", last: true) { BudgetSetupView() }
                        }
                        .card(padding: 2)
                    }

                    section("More") { MoreTiles() }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(MooneeBackground())
            .foregroundStyle(Color.ink)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var reminderBadge: String {
        switch reminderLevel {
        case "low": String(localized: "Low", table: "Account")
        case "high": String(localized: "High", table: "Account")
        default: String(localized: "Medium", table: "Account")
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(verbatim: "Moonee").font(.largeTitle.weight(.bold)).foregroundStyle(Color.brandDeep)
                Image(systemName: "sparkles").font(.title2).foregroundStyle(Color.brandYellow)
            }
            Text("Account & Settings", tableName: "Account")
                .font(.subheadline.weight(.medium)).foregroundStyle(Color.brandDeep)
                .padding(.horizontal, 14).padding(.vertical, 4)
                .background(Color.brandMintSoft, in: .capsule)
            ZStack(alignment: .bottom) {
                Hills().frame(height: 110).padding(.horizontal, -16)
                    .mask(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
                MooneeCharacter(mood: .greeting).frame(height: 150)
            }
        }
        .padding(.top, 8)
    }

    private var profileCard: some View {
        HStack(spacing: 16) {
            ProfileAvatarImage(avatar: avatar, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                if name.isEmpty {
                    Text("Set up your profile", tableName: "Account").font(.title3.weight(.bold))
                } else {
                    Text(name).font(.title3.weight(.bold)).lineLimit(1)
                }
                Text("Stored on this device only", tableName: "Account").font(.subheadline).foregroundStyle(Color.inkSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.body.weight(.semibold)).foregroundStyle(Color.inkSecondary)
        }
        .card()
        .contentShape(.rect)
    }

    private func section(_ title: String.LocalizationValue, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringResource(title, table: "Account")).font(.title3.weight(.bold)).foregroundStyle(Color.brandDeep).padding(.leading, 6)
            content()
        }
    }
}

private struct AccountRow<Destination: View>: View {
    let symbol: String
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
    var badge: String?
    var last = false
    @ViewBuilder let destination: () -> Destination

    init(symbol: String, title: String.LocalizationValue, subtitle: String.LocalizationValue, badge: String? = nil, last: Bool = false,
         @ViewBuilder destination: @escaping () -> Destination) {
        self.symbol = symbol
        self.title = LocalizedStringResource(title, table: "Account")
        self.subtitle = LocalizedStringResource(subtitle, table: "Account")
        self.badge = badge
        self.last = last
        self.destination = destination
    }

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 14) {
                IconBadge(symbol: symbol, color: .brandDeep, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(Color.inkSecondary)
                }
                Spacer(minLength: 4)
                if let badge {
                    Text(badge).font(.footnote.weight(.medium)).foregroundStyle(Color.brandDeep)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Color.brandMintSoft, in: .capsule)
                }
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(Color.inkSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { if !last { Divider().padding(.leading, 68) } }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// "More": rate, share, help, about.
private struct MoreTiles: View {
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        HStack(spacing: 10) {
            Button { requestReview() } label: { tile("star", "Rate the app") }
            ShareLink(item: AppLinks.appStore, message: Text("Moonee: a friendly money assistant", tableName: "Account")) { tile("square.and.arrow.up", "Share Moonee") }
            Link(destination: AppLinks.feedback) { tile("questionmark.circle", "Help & feedback") }
            NavigationLink { AboutView() } label: { tile("info.circle", "About Moonee", detail: AppInfo.version) }
        }
        .buttonStyle(.plain)
    }

    private func tile(_ symbol: String, _ title: String.LocalizationValue, detail: String? = nil) -> some View {
        // Every tile is icon + two text lines; About's second line is the version (as in the mockup).
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.brandPrimary)
            VStack(spacing: 0) {
                Text(LocalizedStringResource(title, table: "Account"))
                    .lineLimit(detail == nil ? 2 : 1, reservesSpace: detail == nil).minimumScaleFactor(0.8)
                if let detail { Text(detail).foregroundStyle(Color.inkSecondary) }
            }
            .font(.footnote).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 104)
        .card(padding: 8)
    }
}

enum AppLinks {
    // ponytail: placeholders until the App Store listing exists (S11): fill in the app id and the support address.
    static let appStore = URL(string: "https://apps.apple.com/app/moonee")!
    static let feedback = URL(string: "mailto:?subject=Moonee%20feedback")!
}

enum AppInfo {
    static var version: String {
        "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
    }
}

/// Settings that existed before this screen: categories, jars, wallets.
private struct BudgetSetupView: View {
    var body: some View {
        Form {
            NavigationLink { CategoriesView() } label: { Label { Text("Categories", tableName: "Account") } icon: { Image(systemName: "tag") } }
            NavigationLink { WalletsView() } label: { Label { Text("Wallets", tableName: "Account") } icon: { Image(systemName: "wallet.bifold") } }
            NavigationLink { JarSettingsView() } label: { Label { Text("Customize jars", tableName: "Account") } icon: { Image(systemName: "square.stack.3d.up") } }
            NavigationLink { JarMappingView() } label: { Label { Text("Assign categories to jars", tableName: "Account") } icon: { Image(systemName: "arrow.triangle.branch") } }
            #if DEBUG
            NavigationLink { ComponentGallery() } label: { Label { Text(verbatim: "Component Gallery") } icon: { Image(systemName: "swatchpalette") } }
            #endif
        }
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .navigationTitle(Text("Categories, jars & wallets", tableName: "Account"))
    }
}

/// About + privacy (spec §6.5).
private struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image("Logo").resizable().frame(width: 88, height: 88).clipShape(.rect(cornerRadius: 22)).padding(.top, 16)
            Text(verbatim: "Moonee").font(.title.bold())
            Text("Version \(AppInfo.version)", tableName: "Account").foregroundStyle(Color.inkSecondary)
            VStack(alignment: .leading, spacing: 12) {
                Text("Privacy", tableName: "Account").font(.headline)
                Text("Moonee has no server and no account. Your data stays on this iPhone (and in your own iCloud when sync is on). Nothing is sent anywhere unless you pick a cloud AI with your own key; AI settings show exactly what is sent.", tableName: "Account")
                Text("Thanks", tableName: "Account").font(.headline)
                Text("Moonee's finance skills adapt ideas from the finance plugin of anthropics/knowledge-work-plugins (Apache-2.0).", tableName: "Account")
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .mooneeScreen(String(localized: "About Moonee", table: "Account"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
