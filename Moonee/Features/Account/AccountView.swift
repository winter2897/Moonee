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
                    NavigationLink { DebtBookView() } label: {
                        SettingsLabel("Debt book", symbol: "person.2.fill", color: .indigo)
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
            // The app introduction comes first, then Terms and Privacy.
            Section {
                VStack(spacing: 6) {
                    Image("moonee.happy").resizable().scaledToFit().frame(height: 110).accessibilityHidden(true)
                    Text(verbatim: "Moonee: Your AI Money Buddy").font(.title3.bold()).foregroundStyle(Color.brandDeep) // brand line, never translated
                        .multilineTextAlignment(.center)
                    Text("Version \(AppInfo.number) (\(AppInfo.build))", tableName: "Account").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                Text("Moonee is a money buddy you chat with. Tell it what you spent in a few words, and it keeps your books, splits your money into jars and tells you what you can still spend.", tableName: "Account")
                    .font(.subheadline)
                feature("bubble.left.and.text.bubble.right.fill", .green, Text("Chat to record", tableName: "Account"), Text("Type, say or snap a receipt: Moonee files it in seconds.", tableName: "Account"))
                feature("square.stack.3d.up.fill", .mint, Text("Money jars", tableName: "Account"), Text("Every income is split into jars, so you always know what is left for each part of life.", tableName: "Account"))
                feature("lock.shield.fill", .blue, Text("Private on your iPhone", tableName: "Account"), Text("No account, no server: your books stay on this iPhone and your own iCloud.", tableName: "Account"))
                feature("sparkles", .purple, Text("AI assistant", tableName: "Account"), Text("Ask anything about your money. Every number is computed by the app; the AI only explains it.", tableName: "Account"))
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

    private func feature(_ symbol: String, _ color: Color, _ title: Text, _ text: Text) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                title.font(.subheadline.weight(.semibold))
                text.font(.footnote).foregroundStyle(.secondary)
            }
        } icon: { SettingsIcon(symbol: symbol, color: color) }
        .accessibilityElement(children: .combine)
    }
}
