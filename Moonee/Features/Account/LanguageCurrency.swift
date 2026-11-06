import SwiftUI

/// Moonee's UI language. Picked in the app, not in iOS Settings: iOS's per-app page only lists languages added to the
/// iPhone, and Lao is not an iPhone language (it sits under "Other Languages"), so a Lao user would never see it there.
enum AppLanguage {
    static let codes = ["en", "vi", "th", "lo"]
    private static let key = "AppleLanguages"

    /// The UI language in its own name, e.g. "English", "Tiếng Việt".
    static var current: String { name(Bundle.main.preferredLocalizations.first ?? "en") }

    static func name(_ code: String) -> String {
        Locale(identifier: code).localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
    }

    /// The language set in Moonee (the app's own `AppleLanguages`, read at launch); nil = follow the iPhone.
    static var chosen: String? {
        get { (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] as? [String])?.first }
        set { newValue.map { UserDefaults.standard.set([$0], forKey: key) } ?? UserDefaults.standard.removeObject(forKey: key) }
    }
}

/// Account → Language: English, Tiếng Việt, ไทย, ລາວ or the iPhone's. Takes effect when Moonee next opens.
struct LanguagePicker: View {
    @State private var selection = AppLanguage.chosen
    @State private var changed = false

    var body: some View {
        List {
            Section {
                row(nil, title: String(localized: "Same as iPhone", table: "Account"), subtitle: nil)
                ForEach(AppLanguage.codes, id: \.self) { code in
                    row(code, title: AppLanguage.name(code), subtitle: Locale.current.localizedString(forLanguageCode: code))
                }
            } footer: {
                if changed { Text("Close Moonee and open it again to switch the language.", tableName: "Account") }
            }
        }
        .navigationTitle(Text("Language", tableName: "Account"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ code: String?, title: String, subtitle: String?) -> some View {
        Button {
            guard code != selection else { return }
            (selection, changed) = (code, true)
            AppLanguage.chosen = code
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(title)
                    if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer()
                if selection == code { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint) }
            }
            .contentShape(.rect)
        }
        .foregroundStyle(.primary)
        .accessibilityAddTraits(selection == code ? .isSelected : [])
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

/// Account → Currency (spec §10.2). nil = follow the device region.
struct CurrencyPicker: View {
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
                Section {
                    row(nil, title: String(localized: "Automatic (\(Locale.current.currency?.identifier ?? "USD"))", table: "Account"),
                        subtitle: String(localized: "From your region", table: "Account"))
                } footer: {
                    Text("Used for new transactions and for amounts like “45k”. Amounts already saved keep their currency.", tableName: "Account")
                }
            }
            Section {
                ForEach(codes, id: \.self) { code in
                    row(code, title: Money.label(code), subtitle: Locale.current.localizedString(forCurrencyCode: code))
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle(Text("Currency", tableName: "Account"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ code: String?, title: String, subtitle: String?) -> some View {
        Button {
            selection = code
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(title)
                    if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer()
                if selection == code { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint) }
            }
            .contentShape(.rect)
        }
        .foregroundStyle(.primary)
        .accessibilityAddTraits(selection == code ? .isSelected : [])
    }
}
