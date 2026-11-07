import SwiftData
import SwiftUI

/// Top of the Budget tab (P0-3, spec §4.1): the month (‹ › or a swipe), then one number.
/// - Money waits in Unallocated: a call to action, "You have 20tr not in a jar yet · Split now", never a red total.
///   A jar below zero that this money can refill gets "Cover from unallocated" (Automatic does it by itself and says so).
/// - Otherwise "Left to spend this month" (Σ jar balances) and "About X a day".
struct BudgetHeader: View {
    @Binding var month: DateInterval
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.balanceHidden) private var hidden
    @Query(sort: \Jar.order) private var jars: [Jar]
    @Query private var txns: [Txn]
    @Query private var wallets: [Wallet]
    @Query(sort: \Recurring.nextDue) private var recurrings: [Recurring]
    @AppStorage(Prefs.advisorLevel) private var level = AdvisorLevel.suggest.rawValue

    private let currency = Money.defaultCurrency

    var body: some View {
        let facts = BudgetFacts(txns: txns, wallets: wallets, jars: jars, recurrings: recurrings, month: month,
                                level: AdvisorLevel(rawValue: level) ?? .suggest)
        let isNow = month.contains(.now)
        Section {
            VStack(alignment: .leading, spacing: 14) {
                monthBar
                if isNow, facts.unallocated > 0 {
                    unsplit(facts)
                } else {
                    left(facts, isNow: isNow)
                }
            }
            .padding(.vertical, 6)
            .contentShape(.rect)
            .simultaneousGesture(swipe)
            if isNow, facts.unallocated < 0 { overpromised(facts.unallocated) }
            // Mascot: a past month that closed within its budget, with no jar in the red, gets a small cheer.
            if month.end <= .now, facts.budget > 0, facts.left >= 0, !facts.jars.contains(where: { $0.balance < 0 }) {
                MooneeNoteCard(mood: .celebrate,
                               text: String(localized: "You kept \(AmountFormat.string(facts.left, currency)) in your jars.", table: "Budget"),
                               title: String(localized: "\(month.start.budgetMonthTitle) closed under budget!", table: "Budget"),
                               animated: true)
            }
        }
    }

    // MARK: - Month

    private var canGoBack: Bool { txns.contains { $0.date < month.start } }
    private var canGoForward: Bool { month.end <= .now }

    private var monthBar: some View {
        HStack {
            chevron("chevron.left", label: loc("Previous month"), enabled: canGoBack) { move(-1) }
            Spacer()
            Text(month.start.budgetMonthTitle).font(.headline).foregroundStyle(Color.ink)
            Spacer()
            chevron("chevron.right", label: loc("Next month"), enabled: canGoForward) { move(1) }
        }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 30).onEnded { g in
            guard abs(g.translation.width) > abs(g.translation.height) * 1.5 else { return }
            if g.translation.width < 0, canGoForward { move(1) } else if g.translation.width > 0, canGoBack { move(-1) }
        }
    }

    private func move(_ step: Int) {
        let cal = Calendar.current
        guard let d = cal.date(byAdding: .month, value: step, to: month.start), let m = cal.dateInterval(of: .month, for: d) else { return }
        if reduceMotion { month = m } else { withAnimation(.smooth) { month = m } }
    }

    private func chevron(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.footnote.weight(.semibold)).frame(width: 36, height: 36)
                .background(Circle().fill(Color.track.opacity(enabled ? 1 : 0.4)))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(enabled ? Color.brandDeep : Color.inkSecondary.opacity(0.5))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: - Numbers

    /// "Left to spend this month", "About X a day", and a meter of what is spent out of "Available this month".
    private func left(_ facts: BudgetFacts, isNow: Bool) -> some View {
        let progress = BudgetLevel.progress(spent: facts.spent, budget: facts.budget)
        let level = BudgetLevel(progress: progress)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isNow ? loc("Left to spend this month") : loc("Left at month end")).font(.subheadline).foregroundStyle(Color.inkSecondary)
                RollingAmount(facts.left, currency: currency).font(.heroAmount)
                    .foregroundStyle(facts.left < 0 ? Color.danger : Color.ink)
                if isNow, facts.perDay > 0 {
                    Text(String(localized: "About \(money(facts.perDay)) a day", table: "Budget"))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.brandDeep)
                }
            }
            TickMeter(progress: progress, color: level.fill, count: 30, height: 22)
            HStack(spacing: 4) {
                if let symbol = level.symbol { Image(systemName: symbol).foregroundStyle(level.text) }
                Text(loc("Spent"))
                AmountText(facts.spent, currency: currency, short: true).fontWeight(.semibold).foregroundStyle(Color.ink)
                Spacer()
                Text(loc("Available this month"))
                AmountText(facts.budget, currency: currency, short: true).fontWeight(.semibold).foregroundStyle(Color.ink)
            }
            .font(.footnote)
            .foregroundStyle(Color.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Unallocated > 0: the money to split is the headline, with the ways to split it.
    private func unsplit(_ facts: BudgetFacts) -> some View {
        let amount = facts.unallocated
        let plan = facts.advisor.advice.first { $0.kind == .unallocated }
        let cover = AdvisorLevel(rawValue: level) == .automatic ? nil : facts.advisor.unallocatedCover
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(symbol: "tray.and.arrow.down.fill", color: .brandDeep, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "You have \(money(amount)) not in a jar yet", table: "Budget"))
                        .font(.rowTitle).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
                    Text(cover.map { c in String(localized: "\(names(c.moves)) is below zero: cover it from this money.", table: "Budget") }
                         ?? loc("Split it into jars to see what you can spend."))
                        .font(.subheadline).foregroundStyle(Color.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Menu {
                    if let plan {
                        Button { done { _ = BudgetActions.apply(plan, in: context); AdvisorMemory.handle(plan) } } label: {
                            Label(loc("Moonee's plan"), systemImage: "lightbulb")
                            Text(plan.text)
                        }
                    }
                    Button(loc("Split by percent"), systemImage: "percent") {
                        done { _ = BudgetActions.splitUnallocated(amount, jars: jars, in: context) }
                    }
                    Menu(loc("All into one jar")) {
                        ForEach(jars) { j in
                            Button(j.name) { done { _ = BudgetActions.allocate([j: amount], note: loc("Split into jars"), in: context) } }
                        }
                    }
                } label: {
                    Label(loc("Split now"), systemImage: "square.stack.3d.up.fill").fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent).tint(Color.brandPrimary)
                if let cover {
                    Button(loc("Cover from unallocated")) { done { _ = BudgetActions.apply(cover, in: context) } }
                        .buttonStyle(.bordered).tint(Color.brandDeep)
                }
            }
            .controlSize(.small)
        }
    }

    /// Unallocated < 0: the jars promise more than the wallets hold (a real problem, so it stays red).
    private func overpromised(_ amount: Int) -> some View {
        BudgetRow(title: loc("Unallocated"), symbol: "exclamationmark.triangle.fill", tint: .danger) {
            Text(loc("More than your wallets hold.")).foregroundStyle(Color.inkSecondary)
        } value: {
            AmountText(amount, currency: currency).foregroundStyle(Color.danger)
        }
    }

    private func names(_ moves: [BudgetAdvisor.Move]) -> String {
        moves.compactMap { m in jars.first { $0.parserKey == m.to }?.name }.formatted(.list(type: .and))
    }

    private func done(_ write: () -> Void) { withAnimation { write() } }

    /// An amount inside a sentence, masked like `AmountText` when balances are hidden.
    private func money(_ minor: Int) -> String { hidden ? AmountFormat.mask : AmountFormat.string(minor, currency, short: true) }
}
