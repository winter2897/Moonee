import StoreKit
import SwiftUI

/// Account tab (spec §6), laid out like the iOS Settings app: profile row, then short grouped sections.
/// Toggles and short pickers sit in their row; only lists (currency, AI, reminders, budget setup) push a screen.
struct AccountView: View {
    @AppStorage(Prefs.profileName) private var name = ""
    @AppStorage(Prefs.profileAvatar) private var avatar = ""
    @AppStorage(LLMSettings.modeKey) private var aiMode = LLMSettings.mode
    @AppStorage(Prefs.reminderLevel) private var reminderLevel = ReminderLevel.medium.rawValue
    @AppStorage(Prefs.advisorLevel) private var advisorLevel = AdvisorLevel.suggest.rawValue
    @AppStorage(Money.currencyKey) private var currency: String?
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { ProfileEditView() } label: { profileRow }
                }

                Section {
                    NavigationLink { LanguagePicker() } label: {
                        LabeledContent { Text(AppLanguage.current) } label: { SettingsLabel("Language", symbol: "globe", color: .blue) }
                    }
                    NavigationLink { CurrencyPicker(selection: $currency) } label: {
                        LabeledContent { Text(Money.label(Money.defaultCurrency)) } label: {
                            SettingsLabel("Currency", symbol: "dollarsign", color: .green)
                        }
                    }
                    NavigationLink { BudgetSetupView() } label: {
                        SettingsLabel("Categories, jars & wallets", symbol: "square.stack.3d.up.fill", color: .orange)
                    }
                } header: {
                    Text("General", tableName: "Account")
                }

                Section {
                    NavigationLink { AISettingsView() } label: {
                        LabeledContent { Text(aiMode.badge) } label: { SettingsLabel("AI assistant", symbol: "sparkles", color: .purple) }
                    }
                }

                Section {
                    NavigationLink { AdvisorSettingsView() } label: {
                        LabeledContent { Text(AdvisorLevel(rawValue: advisorLevel)?.title ?? "") } label: {
                            SettingsLabel("Moonee's help", symbol: "lightbulb.fill", color: .mint)
                        }
                    }
                    NavigationLink { ReminderSettingsView() } label: {
                        LabeledContent { Text(ReminderLevel(rawValue: reminderLevel)?.title ?? "") } label: {
                            SettingsLabel("Reminders", symbol: "bell.badge.fill", color: .red)
                        }
                    }
                }

                SecuritySettings()

                DataSettings()

                Section {
                    Group {
                        Button { requestReview() } label: { SettingsLabel("Rate the app", symbol: "star.fill", color: .yellow) }
                        ShareLink(item: AppLinks.appStore, message: Text("Moonee: a friendly money assistant", tableName: "Account")) {
                            SettingsLabel("Share Moonee", symbol: "square.and.arrow.up", color: .blue)
                        }
                        FeedbackRow()
                    }
                    .foregroundStyle(.primary)
                    NavigationLink { AboutView() } label: {
                        LabeledContent { Text(AppInfo.version) } label: { SettingsLabel("About Moonee", symbol: "info", color: .gray) }
                    }
                } header: {
                    Text("Support & about", tableName: "Account")
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle(Text("Account", tableName: "Account"))
        }
    }

    private var profileRow: some View {
        HStack(spacing: 14) {
            ProfileAvatarImage(avatar: avatar, size: 60)
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if name.isEmpty { Text("Set up your profile", tableName: "Account") } else { Text(name) }
                }
                .font(.title3.weight(.semibold)).lineLimit(1)
                Text("Stored on this device only", tableName: "Account")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A Settings-style row label: SF Symbol, white on a small coloured rounded square, sized with Dynamic Type.
struct SettingsLabel: View {
    let title: LocalizedStringResource
    let symbol: String
    let color: Color

    init(_ title: String.LocalizationValue, symbol: String, color: Color) {
        self.title = LocalizedStringResource(title, table: "Account")
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        Label { Text(title) } icon: { SettingsIcon(symbol: symbol, color: color) }
    }
}

struct SettingsIcon: View {
    let symbol: String
    let color: Color
    @ScaledMetric(relativeTo: .body) private var size = 29

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .rect(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }
}

enum AppLinks {
    // ponytail: placeholder until the App Store listing exists (S11): fill in the app id.
    static let appStore = URL(string: "https://apps.apple.com/app/moonee")!
}

enum AppInfo {
    static var version: String { "v" + number }
    static var number: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }
}

/// Settings that existed before this screen: categories, jars, wallets.
private struct BudgetSetupView: View {
    var body: some View {
        Form {
            NavigationLink { CategoriesView() } label: { SettingsLabel("Categories", symbol: "tag.fill", color: .orange) }
            NavigationLink { WalletsView() } label: { SettingsLabel("Wallets", symbol: "wallet.bifold.fill", color: .green) }
            NavigationLink { JarSettingsView() } label: { SettingsLabel("Customize jars", symbol: "square.stack.3d.up.fill", color: .mint) }
            NavigationLink { JarMappingView() } label: { SettingsLabel("Assign categories to jars", symbol: "arrow.triangle.branch", color: .indigo) }
            #if DEBUG
            NavigationLink { ComponentGallery() } label: { Label { Text(verbatim: "Component Gallery") } icon: { SettingsIcon(symbol: "swatchpalette.fill", color: .pink) } }
            #endif
        }
        .navigationTitle(Text("Categories, jars & wallets", tableName: "Account"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// About + privacy (spec §6.5).
private struct AboutView: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image("Logo").resizable().frame(width: 80, height: 80).clipShape(.rect(cornerRadius: 18))
                    Text(verbatim: "Moonee").font(.title2.bold())
                    Text("Version \(AppInfo.version)", tableName: "Account").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                NavigationLink { TermsView() } label: {
                    Label { Text("Terms & disclaimer", tableName: "Terms") } icon: { SettingsIcon(symbol: "doc.text.fill", color: .gray) }
                }
            }
            Section {
                Text("Moonee has no server and no account. Your data stays on this iPhone (and in your own iCloud when sync is on). Nothing is sent anywhere unless you pick a cloud AI with your own key; AI settings show exactly what is sent.", tableName: "Account")
            } header: {
                Text("Privacy", tableName: "Account")
            }
        }
        .navigationTitle(Text("About Moonee", tableName: "Account"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
