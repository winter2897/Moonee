import SwiftData
import SwiftUI
import UserNotifications

private func L(_ key: String.LocalizationValue) -> String { String(localized: key, table: "Onboarding") }

/// Onboarding steps 2–4 (spec §7) as a scripted chat: Moonee asks, the answer panel under the last bubble replies.
/// Every question has a Skip; ✕ ends the whole setup. Each answer is written right away through `OnboardingBook`.
struct OnboardingChat: View {
    var onFinish: () -> Void

    enum Question {
        case income, regular, payday, wallets, bills, jars, advisor, aiMode, reminders, security, done
        /// The progress bar: step 2 money, 3 budget, 4 assistant.
        var step: Int {
            switch self {
            case .income, .regular, .payday, .wallets: 2
            case .bills, .jars, .advisor: 3
            case .aiMode, .reminders, .security, .done: 4
            }
        }
    }

    private struct Line: Identifiable {
        let id = UUID()
        let fromUser: Bool
        let text: String
    }

    private struct WalletRow: Identifiable {
        let type: WalletType
        var on: Bool
        var amount = ""
        var id: WalletType { type }
    }

    private struct BillRow: Identifiable {
        let id = UUID()
        var name: String
        var amount = ""
        var day: Int
        var categoryKey: String
        var symbol: String
    }

    @Environment(\.modelContext) private var context
    @Query(sort: \Jar.order) private var jars: [Jar]
    @AppStorage(Prefs.profileName) private var name = ""
    @State private var lines: [Line] = []
    @State private var question = Question.income
    @State private var income: Int?
    @State private var regular: Bool?
    @State private var typedIncome = ""
    @State private var wallets = WalletType.allCases.map { WalletRow(type: $0, on: $0 == .cash) }
    @State private var bills: [BillRow] = []
    @State private var billsTotal = 0
    @State private var percents: [Int] = []
    @State private var faceID = false
    @State private var notifications = false
    @FocusState private var focused: Bool

    private var currency: String { Money.defaultCurrency }
    private var suggestedMode: AIMode {
        OnboardingBook.suggestedMode(appleAvailable: AppleLLM.isAvailable, localFits: LocalModel.recommended() != nil,
                                     language: Assistant.uiLanguage)
    }

    var body: some View {
        VStack(spacing: 0) {
            MooneeHeader(Text("Quick setup", tableName: "Onboarding")) {
                Button(action: onFinish) { HeaderCircle("xmark") }
                    .accessibilityLabel(Text("Skip setup", tableName: "Onboarding"))
            }
            .padding(.horizontal, 16)
            StepProgress(step: question.step).padding(.top, 2).padding(.bottom, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        MooneeHero(mood: question == .done ? .celebrate : .greeting, compact: true)
                        ForEach(lines.indices, id: \.self) { i in
                            let line = lines[i]
                            Group {
                                if line.fromUser {
                                    ChatBubble(.user, line.text, sent: true)
                                } else {
                                    ChatBubble(.moonee, line.text, showsAvatar: i == 0 || lines[i - 1].fromUser)
                                }
                            }
                            .id(line.id)
                        }
                        panel
                            .padding(.leading, 42) // under the bubbles, past Moonee's avatar
                    }
                    .padding(.horizontal, 16).padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: lines.count) {
                    // The new question at the top, its answer panel under it; after layout so the panel is measured.
                    guard let last = lines.last?.id else { return }
                    Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        withAnimation(.smooth) { proxy.scrollTo(last, anchor: .top) }
                    }
                }
            }
        }
        .foregroundStyle(Color.ink)
        .onAppear {
            guard lines.isEmpty else { return }
            let hi = name.isEmpty ? L("Hi there! I'm **Moonee**, your money buddy 👋") : L("Nice to meet you, **\(name)**! I'm **Moonee**, your money buddy 👋")
            lines = [.init(fromUser: false, text: hi + "\n" + L("A few quick questions and your budget is ready. Skip anything you like.")),
                     .init(fromUser: false, text: prompt(.income))]
        }
    }

    // MARK: - Script

    private func prompt(_ q: Question) -> String {
        switch q {
        case .income: return L("About how much do you earn a month? A rough range is fine.")
        case .regular: return L("Is it a fixed salary, or does it change from month to month?")
        case .payday: return L("Which day of the month does it usually come in? On that day Moonee asks you to confirm it and splits it into your jars.")
        case .wallets: return L("Where do you keep your money? Tick your wallets and what is in them today.")
        case .bills: return L("Any fixed bills every month? Tap one to add it with its amount and due day.")
        case .jars:
            var why: [String] = []
            if regular == false, jars.contains(where: { $0.key == "jar.savings" }) {
                why.append(L("Your income varies, so **Savings** gets a little more."))
            }
            if let e = jars.firstIndex(where: { $0.key == "jar.essentials" }), percents.indices.contains(e), percents[e] > jars[e].percent {
                why.append(L("Your bills take a big bite, so **Essentials** gets more room."))
            }
            return ([L("Here's how Moonee would split every income into jars.")] + why
                    + [L("Keep it or tweak it: it has to add up to 100%.")]).joined(separator: " ")
        case .advisor: return L("How much should Moonee help with your money? You can change it any time in Account.")
        case .aiMode:
            return L("Which brain should Moonee use? For this iPhone Moonee suggests **\(suggestedMode.title)**. You can change it any time in Account.")
        case .reminders: return L("How often should Moonee nudge you?")
        case .security: return L("Last one: lock Moonee with Face ID, and allow reminders?")
        case .done:
            return name.isEmpty ? L("All set! 🎉 Tap + and tell Moonee your first spend, like “lunch 45k”.")
                                : L("All set, \(name)! 🎉 Tap + and tell Moonee your first spend, like “lunch 45k”.")
        }
    }

    /// Records the user's reply (or "Skip"), moves on and asks the next question.
    private func answer(_ said: String, next: Question) {
        focused = false
        try? context.save()
        if next == .jars {
            let keys = jars.map(\.key)
            percents = OnboardingBook.proposePercents(keys: keys, current: jars.map(\.percent), monthlyIncome: income,
                                                      regular: regular, billsTotal: billsTotal)
        }
        withAnimation(.smooth) {
            lines.append(.init(fromUser: true, text: said))
            question = next
            lines.append(.init(fromUser: false, text: prompt(next)))
        }
    }

    private func skip(to next: Question) { answer(L("Skip for now"), next: next) }

    private func amount(_ text: String) -> Int? { OnboardingBook.amount(text, context: ParserContext(context)) }

    private func money(_ minor: Int) -> String { AmountFormat.string(minor, currency) }

    // MARK: - Answer panels

    @ViewBuilder private var panel: some View {
        switch question {
        case .income: incomePanel
        case .regular: regularPanel
        case .payday: paydayPanel
        case .wallets: walletsPanel
        case .bills: billsPanel
        case .jars: jarsPanel
        case .advisor: advisorPanel
        case .aiMode: aiModePanel
        case .reminders: remindersPanel
        case .security: securityPanel
        case .done:
            Button(action: onFinish) { Text("Start using Moonee", tableName: "Onboarding") }
                .buttonStyle(MooneeButtonStyle())
        }
    }

    private var incomePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], alignment: .leading, spacing: 0) {
                ForEach(OnboardingBook.incomeRanges(currency: currency), id: \.label) { r in
                    QuickReplyChip(title: r.label) { setIncome(r.mid, said: r.label) }
                }
            }
            HStack(spacing: 4) {
                amountField(L("Or type the amount"), text: $typedIncome)
                Button {
                    if let a = amount(typedIncome) { setIncome(a, said: money(a)) }
                } label: {
                    Image(systemName: "paperplane.fill").font(.body.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40).background(LinearGradient.brand, in: .circle)
                        .frame(width: 44, height: 44).contentShape(.circle)
                }
                .disabled(amount(typedIncome) == nil)
                .opacity(amount(typedIncome) == nil ? 0.45 : 1)
                .accessibilityLabel(Text("Send", tableName: "Onboarding"))
            }
            skipButton { skip(to: .regular) }
        }
    }

    private func setIncome(_ minor: Int, said: String) {
        income = minor
        UserDefaults.standard.set(minor, forKey: Prefs.monthlyIncome)
        answer(said, next: .regular)
    }

    private var regularPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                QuickReplyChip(title: L("Fixed salary"), symbol: "calendar") { setRegular(true, said: L("Fixed salary")) }
                QuickReplyChip(title: L("It varies"), symbol: "waveform.path.ecg") { setRegular(false, said: L("It varies")) }
            }
            skipButton { skip(to: income == nil ? .wallets : .payday) }
        }
    }

    private func setRegular(_ value: Bool, said: String) {
        regular = value
        UserDefaults.standard.set(value, forKey: Prefs.incomeRegular)
        answer(said, next: income == nil ? .wallets : .payday)
    }

    private var paydayPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 0) {
                ForEach([1, 5, 10, 15, 20, 25], id: \.self) { day in
                    QuickReplyChip(title: L("Day \(day)")) { setPayday(day) }
                }
            }
            Menu {
                ForEach(1...31, id: \.self) { day in Button(L("Day \(day)")) { setPayday(day) } }
            } label: {
                Label(L("Another day"), systemImage: "calendar").font(.chip.weight(.semibold)).foregroundStyle(Color.brandDeep)
                    .frame(minHeight: 44).contentShape(.rect)
            }
            skipButton { skip(to: .wallets) }
        }
    }

    private func setPayday(_ day: Int) {
        if let income { OnboardingBook.saveSalary(income, payday: day, regular: regular, in: context) }
        answer(L("Day \(day)"), next: .wallets)
    }

    private var walletsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                ForEach($wallets) { $w in
                    HStack(spacing: 10) {
                        Button { withAnimation(.snappy) { w.on.toggle() } } label: {
                            HStack(spacing: 10) {
                                Image(systemName: w.on ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(w.on ? Color.brandPrimary : Color.inkSecondary)
                                IconBadge(symbol: w.type.symbol, color: w.type.color, size: 30)
                                Text(w.type.title).font(.rowTitle).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(minHeight: 44).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(w.on ? .isSelected : [])
                        Spacer(minLength: 4)
                        if w.on {
                            TextField(w.type == .credit ? L("Owed") : L("Balance"), text: $w.amount)
                                .font(.bodyText).multilineTextAlignment(.trailing)
                                .keyboardType(.numbersAndPunctuation).focused($focused)
                                .frame(maxWidth: 130)
                        }
                    }
                    if w.type != wallets.last?.type { Divider().padding(.leading, 74) }
                }
            }
            .card(padding: 12)
            Button(action: saveWallets) { Text("Save wallets", tableName: "Onboarding") }
                .buttonStyle(MooneeButtonStyle())
                .disabled(!wallets.contains(where: \.on))
            skipButton { skip(to: .bills) }
        }
    }

    private func saveWallets() {
        let drafts = wallets.filter(\.on).map { OnboardingBook.WalletDraft(type: $0.type, name: "", amount: amount($0.amount) ?? 0) }
        let saved = OnboardingBook.saveWallets(drafts, in: context)
        let said = saved.map { w in
            let owed = w.type == .credit
            return "\(w.name) · \(money(owed ? -w.initialBalance : w.initialBalance))\(owed ? " " + L("owed") : "")"
        }
        answer(said.joined(separator: "\n"), next: .bills)
    }

    private var billsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            let unused = OnboardingBook.billSuggestions.filter { s in !bills.contains { $0.name == s.name } }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 0) {
                ForEach(unused, id: \.name) { s in
                    QuickReplyChip(title: s.name, symbol: s.symbol) { addBill(s) }
                }
                QuickReplyChip(title: L("Other"), symbol: "plus") {
                    addBill(.init(name: "", amount: 0, day: 1, categoryKey: "category.other", symbol: "doc.text.fill"))
                }
            }
            if !bills.isEmpty {
                VStack(spacing: 0) {
                    ForEach($bills) { $b in
                        HStack(spacing: 10) {
                            IconBadge(symbol: b.symbol, color: .brandDeep, size: 30)
                            VStack(alignment: .leading, spacing: 4) {
                                TextField(L("Bill name"), text: $b.name).font(.rowTitle).focused($focused)
                                HStack(spacing: 8) {
                                    TextField(L("Amount"), text: $b.amount)
                                        .font(.bodyText).keyboardType(.numbersAndPunctuation).focused($focused)
                                    Picker(selection: $b.day) {
                                        ForEach(1...31, id: \.self) { Text("Day \($0)", tableName: "Onboarding").tag($0) }
                                    } label: { Text("Due day", tableName: "Onboarding") }
                                    .pickerStyle(.menu).font(.secondaryText).fixedSize()
                                }
                            }
                            Button { withAnimation(.snappy) { bills.removeAll { $0.id == b.id } } } label: {
                                Image(systemName: "minus.circle.fill").font(.title3).foregroundStyle(Color.inkSecondary)
                                    .frame(width: 44, height: 44).contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Remove", tableName: "Onboarding"))
                        }
                        .padding(.vertical, 4)
                        if b.id != bills.last?.id { Divider().padding(.leading, 40) }
                    }
                }
                .card(padding: 12)
                Button(action: saveBills) { Text("Save bills", tableName: "Onboarding") }
                    .buttonStyle(MooneeButtonStyle())
                    .disabled(!bills.contains { amount($0.amount) != nil })
            }
            skipButton(L("No fixed bills")) { answer(L("No fixed bills"), next: .jars) }
        }
    }

    private func addBill(_ s: OnboardingBook.BillDraft) {
        withAnimation(.snappy) {
            bills.append(.init(name: s.name, day: s.day, categoryKey: s.categoryKey, symbol: s.symbol))
        }
    }

    private func saveBills() {
        let drafts = bills.map { OnboardingBook.BillDraft(name: $0.name, amount: amount($0.amount) ?? 0, day: $0.day, categoryKey: $0.categoryKey) }
        let saved = OnboardingBook.saveBills(drafts, in: context)
        billsTotal = saved.reduce(0) { $0 + $1.amount }
        let said = saved.map { "\($0.name) · \(money($0.amount)) · " + L("day \(Calendar.current.component(.day, from: $0.nextDue))") }
        answer(said.isEmpty ? L("No fixed bills") : said.joined(separator: "\n"), next: .jars)
    }

    private var jarsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            let total = percents.reduce(0, +)
            VStack(spacing: 0) {
                ForEach(Array(jars.enumerated()), id: \.element.persistentModelID) { i, jar in
                    if percents.indices.contains(i) {
                        HStack(spacing: 8) {
                            IconBadge(symbol: jar.icon, color: jar.color, size: 30)
                            Text(jar.name).font(.rowTitle).lineLimit(2).minimumScaleFactor(0.9)
                            Spacer(minLength: 4)
                            stepButton("minus", disabled: percents[i] <= 0) { percents[i] -= 5 }
                                .accessibilityLabel(Text("Less for \(jar.name)", tableName: "Onboarding"))
                            Text(verbatim: "\(percents[i])%").font(.rowTitle).monospacedDigit().frame(minWidth: 40)
                            stepButton("plus", disabled: percents[i] >= 100) { percents[i] += 5 }
                                .accessibilityLabel(Text("More for \(jar.name)", tableName: "Onboarding"))
                        }
                        if i < jars.count - 1 { Divider().padding(.leading, 38) }
                    }
                }
                Divider()
                HStack {
                    Text("Total", tableName: "Onboarding").font(.rowTitle)
                    Spacer()
                    Label {
                        Text(verbatim: "\(total)%").monospacedDigit()
                    } icon: {
                        Image(systemName: total == 100 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    }
                    .font(.rowTitle)
                    .foregroundStyle(total == 100 ? Color.brandDeep : Color.warningText)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
            }
            .card(padding: 12)
            Button(action: saveJars) { Text("Use these jars", tableName: "Onboarding") }
                .buttonStyle(MooneeButtonStyle())
                .disabled(!BudgetActions.percentsValid(percents))
            skipButton(L("Keep the defaults")) {
                OnboardingBook.applyJars(jars.map(\.percent), to: jars, in: context)
                answer(L("Keep the defaults"), next: .advisor)
            }
        }
    }

    private func stepButton(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { action() } } label: {
            Image(systemName: symbol).font(.footnote.weight(.bold)).foregroundStyle(Color.brandDeep)
                .frame(width: 30, height: 30).background(Color.brandMintSoft, in: .circle)
                .frame(width: 44, height: 44).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    private func saveJars() {
        OnboardingBook.applyJars(percents, to: jars, in: context)
        answer(zip(jars, percents).map { "\($0.name) \($1)%" }.joined(separator: " · "), next: .advisor)
    }

    /// Spec §7 step 3: Moonee's help level (spec §4.6), Suggest by default.
    private var advisorPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([AdvisorLevel.suggest, .automatic, .manual]) { level in
                optionRow(title: level.title, detail: level.summary, badge: level == .suggest ? L("Default") : nil) {
                    UserDefaults.standard.set(level.rawValue, forKey: Prefs.advisorLevel)
                    answer(level.title, next: .aiMode)
                }
            }
            skipButton { skip(to: .aiMode) }
        }
    }

    private var aiModePanel: some View {
        let suggested = suggestedMode
        return VStack(alignment: .leading, spacing: 8) {
            ForEach([suggested] + AIMode.allCases.filter { $0 != suggested }, id: \.self) { mode in
                optionRow(title: mode.title, detail: mode.summary, badge: mode == suggested ? L("Suggested") : nil) {
                    UserDefaults.standard.set(mode.rawValue, forKey: LLMSettings.modeKey)
                    answer(mode.title, next: .reminders)
                }
            }
            skipButton { skip(to: .reminders) }
        }
    }

    private var remindersPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ReminderLevel.allCases) { level in
                optionRow(title: level.title, detail: level.summary, badge: level == .medium ? L("Default") : nil) {
                    UserDefaults.standard.set(level.rawValue, forKey: Prefs.reminderLevel)
                    answer(level.title, next: .security)
                }
            }
            skipButton { skip(to: .security) }
        }
    }

    private func optionRow(title: String, detail: String, badge: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.rowTitle)
                        if let badge {
                            Text(badge).font(.caption.weight(.semibold)).foregroundStyle(Color.brandDeep)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Color.brandMintSoft, in: .capsule)
                        }
                    }
                    Text(detail).font(.secondaryText).foregroundStyle(Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.inkSecondary)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .card(padding: 12)
        }
        .buttonStyle(PressScaleStyle())
    }

    private var securityPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                toggleRow(L("Lock with Face ID"), symbol: "faceid", on: faceID) {
                    Task {
                        if let failure = await AppLock.authenticate(reason: L("Turn on the app lock")) {
                            if !failure.isEmpty { withAnimation { lines.append(.init(fromUser: false, text: failure)) } }
                        } else {
                            faceID = true
                            UserDefaults.standard.set(true, forKey: Prefs.appLock)
                        }
                    }
                }
                Divider().padding(.leading, 40)
                toggleRow(L("Allow notifications"), symbol: "bell.badge", on: notifications) {
                    Task {
                        // S6's scheduler asks only for provisional permission; onboarding asks for real alerts (spec §7 step 7).
                        notifications = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                    }
                }
            }
            .card(padding: 12)
            Button {
                let said = [faceID ? L("Face ID on") : nil, notifications ? L("Notifications on") : nil].compactMap { $0 }
                answer(said.isEmpty ? L("Not now") : said.joined(separator: " · "), next: .done)
            } label: { Text("Finish setup", tableName: "Onboarding") }
                .buttonStyle(MooneeButtonStyle())
            skipButton(L("Not now")) { answer(L("Not now"), next: .done) }
        }
    }

    private func toggleRow(_ title: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconBadge(symbol: symbol, color: .brandDeep, size: 30)
                Text(title).font(.rowTitle)
                Spacer(minLength: 4)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(on ? Color.brandPrimary : Color.inkSecondary)
            }
            .frame(minHeight: 44).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(on)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: - Bits

    private func amountField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.bodyText)
            .keyboardType(.numbersAndPunctuation)
            .focused($focused)
            .padding(.horizontal, 14).frame(minHeight: 40)
            .background(Color.surface, in: .capsule)
    }

    private func skipButton(_ title: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title ?? L("Skip")).font(.chip.weight(.semibold)).foregroundStyle(Color.brandDeep)
                .frame(minHeight: 44).contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
