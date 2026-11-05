import SwiftUI

/// Budget level shared by jar cards, bars and rings (spec §E: normal / ≥80% / over / negative).
enum BudgetLevel: Equatable {
    case normal, warning, over, negative

    /// `budget` = jar balance at month start + money split in this month; `spent` = spent this month.
    init(balance: Int = 0, spent: Int, budget: Int) {
        if spent > budget { self = .over }
        else if balance < 0 { self = .negative }
        else if budget > 0, spent * 5 >= budget * 4 { self = .warning }
        else { self = .normal }
    }

    /// For rings that only know a fraction.
    init(progress: Double) {
        self = progress > 1 ? .over : progress >= 0.8 ? .warning : .normal
    }

    var fill: Color {
        switch self {
        case .normal: .brandPrimary
        case .warning: .warning
        case .over, .negative: .danger
        }
    }

    var text: Color {
        switch self {
        case .normal: .brandDeep
        case .warning: .warningText
        case .over, .negative: .danger
        }
    }

    /// Non-colour cue (spec §F).
    var symbol: String? {
        switch self {
        case .normal: nil
        case .warning: "exclamationmark.triangle.fill"
        case .over, .negative: "exclamationmark.circle.fill"
        }
    }

    static func progress(spent: Int, budget: Int) -> Double {
        budget > 0 ? Double(spent) / Double(budget) : (spent > 0 ? 1 : 0)
    }
}

/// Rounded progress bar; overflow is clamped to full.
struct MooneeProgressBar: View {
    let progress: Double
    var tint: Color = .brandPrimary
    var height: CGFloat = 8

    var body: some View {
        Capsule().fill(Color.track)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(tint).frame(width: g.size.width * min(max(progress, 0), 1))
                }
            }
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

/// Percent pill ("59%"), with an icon when the level is not normal.
struct PercentChip: View {
    let percent: Int
    let level: BudgetLevel

    var body: some View {
        HStack(spacing: 3) {
            if let symbol = level.symbol { Image(systemName: symbol).imageScale(.small) }
            Text("\(percent)%").monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
        .font(.caption.weight(.semibold))
        .foregroundStyle(level.text)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(level == .normal ? Color.brandMintSoft : level.fill.opacity(0.14), in: .capsule)
    }
}

/// Jar envelope: the big number is the current balance; the bar is spent this month / this month's budget.
struct JarCard: View {
    enum Layout { case row, tile }

    let name: String
    let symbol: String
    let color: Color
    let balance: Int
    let spent: Int
    let budget: Int
    let currency: String
    /// Small text under the name in the row layout, e.g. the income split "55%".
    var subtitle: String? = nil
    var layout: Layout = .row
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.balanceHidden) private var hidden

    private var level: BudgetLevel { BudgetLevel(balance: balance, spent: spent, budget: budget) }
    private var progress: Double { BudgetLevel.progress(spent: spent, budget: budget) }
    private var percent: Int { Int((progress * 100).rounded()) }

    var body: some View {
        Group {
            switch layout {
            case .row: row
            case .tile: tile
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// One line, as in the Budget mockup: icon · name / split · bar over "spent / budget" · % chip · chevron.
    /// No background: the screen groups the rows in one `.card()` with dividers. At accessibility sizes the bar block drops under the name.
    private var row: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
        return HStack(spacing: 8) {
            IconBadge(symbol: symbol, color: color)
            layout {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.rowTitle).foregroundStyle(Color.ink).lineLimit(2).minimumScaleFactor(0.85)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Color.inkSecondary) }
                }
                .frame(maxWidth: typeSize.isAccessibilitySize ? nil : 96, alignment: .leading)
                .layoutPriority(1) // the name takes what it needs (≤ 96 pt), the bar gets the rest
                VStack(alignment: .trailing, spacing: 4) {
                    MooneeProgressBar(progress: progress, tint: level.fill, height: 6)
                    // One Text so both amounts shrink together; full amounts in lists (spec §B).
                    Text(verbatim: hidden ? AmountFormat.mask : "\(AmountFormat.string(spent, currency)) / \(AmountFormat.string(budget, currency))")
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(Color.inkSecondary)
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
                .frame(maxWidth: .infinity)
            }
            PercentChip(percent: percent, level: level)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.inkSecondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6).padding(.horizontal, 12)
        .frame(minHeight: 46)
        .contentShape(.rect)
    }

    /// Fits 4 across a card (≈ 80 pt each): give it `maxWidth: .infinity`. Amounts are short here (rule in spec §B).
    private var tile: some View {
        VStack(spacing: 5) {
            IconBadge(symbol: symbol, color: color, size: 30)
            Text(name).font(.secondaryText.weight(.semibold)).foregroundStyle(Color.ink).lineLimit(1).minimumScaleFactor(0.75)
            AmountText(balance, currency: currency, short: true)
                .font(.caption.weight(.bold))
                .foregroundStyle(balance < 0 ? Color.danger : Color.ink)
            HStack(spacing: 6) {
                MooneeProgressBar(progress: progress, tint: level.fill, height: 6)
                HStack(spacing: 1) {
                    if let s = level.symbol { Image(systemName: s).imageScale(.small) }
                    Text("\(percent)%").monospacedDigit()
                }
                .fixedSize()
                .font(.caption2.weight(.semibold))
                .foregroundStyle(level == .normal ? Color.inkSecondary : level.text)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color.surface.opacity(0.85), in: .rect(cornerRadius: 16))
        .shadow(color: .brandDeep.opacity(0.06), radius: 8, y: 3)
    }
}
