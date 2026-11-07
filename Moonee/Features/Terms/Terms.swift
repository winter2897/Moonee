import SwiftUI

extension Prefs {
    /// Int. The `Terms.version` the user accepted (0 = never). Launch with `-terms.acceptedVersion 1` to skip the consent screen.
    static let termsVersion = "terms.acceptedVersion"
    /// Date. When they accepted it.
    static let termsAcceptedAt = "terms.acceptedAt"
}

/// Terms of Use + AI disclaimer (docs/TERMS.md). The text is `terms.<lang>.md` in the bundle.
enum Terms {
    /// Raise when the meaning of the terms changes: everyone is asked to accept again on the next launch.
    static let version = 1

    static func needsConsent(accepted: Int) -> Bool { accepted < version }

    static func accept(_ defaults: UserDefaults = .standard, now: Date = .now) {
        defaults.set(version, forKey: Prefs.termsVersion)
        defaults.set(now, forKey: Prefs.termsAcceptedAt)
    }

    static func text(language: String = Assistant.uiLanguage) -> String { Skill.resource("terms", language: language) }

    // MARK: Footer under market / investing answers

    static var footer: String { String(localized: "Reference information, not investment advice.", table: "Terms") }
    /// What the chat appends to the reply (italic, its own paragraph).
    static var footerLine: String { "\n\n_\(footer)_" }

    // ponytail: a short word list per language; move to the Lexicons if it needs to grow.
    static let investingWords = [
        "invest", "stock", "shares", "crypto", "bitcoin", "gold", "forex",
        "đầu tư", "cổ phiếu", "chứng khoán", "coin", "tiền ảo", "vàng", "ngoại tệ",
        "ลงทุน", "หุ้น", "คริปโต", "ทอง", "บิตคอยน์",
        "ລົງທຶນ", "ຫຸ້ນ", "ຄຣິບໂຕ", "ທອງຄຳ", "ລາຄາຄຳ",
    ]

    /// Only answers about markets or investing get the footer, not every message.
    static func needsFooter(skill: String, question: String) -> Bool {
        if skill == Skill.marketLookup.id { return true }
        let q = question.lowercased()
        return investingWords.contains { q.contains($0) }
    }
}

// MARK: - Consent (onboarding step 0, and again when `Terms.version` rises)

struct ConsentView: View {
    /// An existing user who accepted an older version.
    var updated = false
    var onAccept: () -> Void = {}
    @State private var agreed = false
    @State private var showTerms = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.title3.weight(.semibold)).foregroundStyle(Color.brandYellow)
                    Text(verbatim: "Moonee").font(.screenTitle).foregroundStyle(Color.brandDeep)
                }
                .accessibilityElement(children: .ignore).accessibilityLabel(Text(verbatim: "Moonee"))
                Group {
                    if updated { Text("We updated our terms", tableName: "Terms") } else { Text("Before we start", tableName: "Terms") }
                }
                .font(.title.bold()).foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                Text("Please read and accept these points to use Moonee.", tableName: "Terms")
                    .font(.bodyText).foregroundStyle(Color.inkSecondary).multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 14) {
                    point("book.closed.fill", Text("Moonee is a record-keeping and budgeting tool, not a financial, investment, tax or legal adviser.", tableName: "Terms"))
                    point("sparkles", Text("AI answers can be wrong. They only analyse the numbers you enter.", tableName: "Terms"))
                    point("nosign", Text("Moonee never tells you to buy, sell or hold stocks, crypto, gold or currencies, and never predicts prices.", tableName: "Terms"))
                    point("person.fill.checkmark", Text("Your money decisions are yours alone. The app maker, AI model makers and AI providers are not liable for them.", tableName: "Terms"))
                    point("lock.iphone", Text("Your data stays on this iPhone and your iCloud. With your own AI key, messages go to the provider you chose.", tableName: "Terms"))
                    Button { showTerms = true } label: {
                        Label { Text("Read the full terms", tableName: "Terms") } icon: { Image(systemName: "doc.text") }
                            .font(.subheadline.weight(.semibold))
                    }
                    .tint(.brandAction)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                Toggle(isOn: $agreed) {
                    Text("I am 18 or older and I agree to the Terms of Use and AI disclaimer.", tableName: "Terms")
                        .font(.subheadline).foregroundStyle(Color.ink)
                }
                .toggleStyle(CheckboxStyle())
                .padding(.horizontal, 4)

                Button(action: accept) { Text("I agree", tableName: "Terms") }
                    .buttonStyle(MooneeButtonStyle())
                    .disabled(!agreed)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(MooneeBackground())
        .sheet(isPresented: $showTerms) {
            NavigationStack {
                TermsView().toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button { showTerms = false } label: { Text("Done", tableName: "Terms") } }
                }
            }
        }
    }

    private func point(_ symbol: String, _ text: Text) -> some View {
        Label { text.font(.subheadline).foregroundStyle(Color.ink) } icon: {
            Image(systemName: symbol).foregroundStyle(Color.brandAction).frame(width: 24)
        }
    }

    private func accept() {
        withAnimation(.smooth) { Terms.accept() }
        onAccept()
    }
}

private struct CheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.title3).foregroundStyle(configuration.isOn ? Color.brandAction : Color.inkSecondary)
                configuration.label.multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
    }
}

// MARK: - Full text (consent sheet, Account → About)

struct TermsView: View {
    @AppStorage(Prefs.termsVersion) private var accepted = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(Terms.text().components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, block in
                    self.block(block.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if accepted > 0, let date = UserDefaults.standard.object(forKey: Prefs.termsAcceptedAt) as? Date {
                    Text("You accepted version \(accepted) on \(date.formatted(date: .long, time: .omitted)).", tableName: "Terms")
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(Text("Terms & disclaimer", tableName: "Terms"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func block(_ b: String) -> some View {
        if b.hasPrefix("# ") {
            Text(verbatim: String(b.dropFirst(2))).font(.title2.bold()).accessibilityAddTraits(.isHeader)
        } else if b.hasPrefix("## ") {
            Text(verbatim: String(b.dropFirst(3))).font(.headline).padding(.top, 6).accessibilityAddTraits(.isHeader)
        } else if b.hasPrefix("- ") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(b.components(separatedBy: "\n").map { String($0.dropFirst(2)) }, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text(verbatim: "•"); Text(verbatim: item) }
                }
            }
        } else if !b.isEmpty {
            Text(verbatim: b)
        }
    }
}
