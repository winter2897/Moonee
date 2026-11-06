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
