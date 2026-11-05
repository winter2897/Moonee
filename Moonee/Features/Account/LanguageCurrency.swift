import SwiftUI

enum AppLanguage {
    /// The UI language in its own name, e.g. "English", "Tiếng Việt".
    static var current: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: code).localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
    }
}

extension Money {
    /// "VND (₫)".
    static func label(_ code: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        let symbol = f.currencySymbol ?? code
        return symbol == code ? code : "\(code) (\(symbol))"
    }
}

/// Account → Language & currency (spec §6.1, §10.2). Language is iOS's per-app setting; currency is ours.
struct LanguageCurrencyView: View {
    @Environment(\.openURL) private var openURL
    @AppStorage(Money.currencyKey) private var currency: String?

    var body: some View {
        Form {
            Section {
                Button {
                    openURL(URL(string: UIApplication.openSettingsURLString)!)
                } label: {
                    LabeledContent {
                        HStack { Text(AppLanguage.current); Image(systemName: "arrow.up.forward.app") }
                    } label: {
                        Label { Text("Language", tableName: "Account") } icon: { Image(systemName: "globe") }
                    }
                }
                .foregroundStyle(Color.ink)
            } footer: {
                Text("Opens Moonee in the Settings app, where iOS lets you pick the app's language.", tableName: "Account")
            }

            Section {
                NavigationLink {
                    CurrencyPicker(selection: $currency)
                } label: {
                    LabeledContent {
                        Text(Money.label(Money.defaultCurrency))
                    } label: {
                        Label { Text("Currency", tableName: "Account") } icon: { Image(systemName: "dollarsign.circle") }
                    }
                }
            } footer: {
                Text("Used for new transactions and for amounts like “45k”. Amounts already saved keep their currency.", tableName: "Account")
            }
        }
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .navigationTitle(Text("Language & currency", tableName: "Account"))
    }
}

/// nil = follow the device region.
private struct CurrencyPicker: View {
    @Binding var selection: String?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var codes: [String] {
        let all = Locale.commonISOCurrencyCodes
        guard !search.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(search) || (Locale.current.localizedString(forCurrencyCode: $0) ?? "").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            if search.isEmpty {
                row(nil, title: String(localized: "Automatic (\(Locale.current.currency?.identifier ?? "USD"))", table: "Account"),
                    subtitle: String(localized: "From your region", table: "Account"))
            }
            ForEach(codes, id: \.self) { code in
                row(code, title: Money.label(code), subtitle: Locale.current.localizedString(forCurrencyCode: code))
            }
        }
        .searchable(text: $search)
        .navigationTitle(Text("Currency", tableName: "Account"))
    }

    private func row(_ code: String?, title: String, subtitle: String?) -> some View {
        Button {
            selection = code
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(title)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Color.inkSecondary) }
                }
                Spacer()
                if selection == code { Image(systemName: "checkmark").foregroundStyle(Color.brandDeep) }
            }
            .contentShape(.rect)
        }
        .foregroundStyle(Color.ink)
    }
}
