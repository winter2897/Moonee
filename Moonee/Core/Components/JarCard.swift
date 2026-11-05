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
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(level.text)
        .padding(.horizontal, 10).padding(.vertical, 5)
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
    /// Small text under the bar in the row layout, e.g. the income split "55%".
    var subtitle: String? = nil
    var layout: Layout = .row

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

    private var row: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: symbol, color: color, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name).font(.headline).foregroundStyle(Color.ink)
                    Spacer(minLength: 4)
                    AmountText(balance, currency: currency)
                        .font(.headline)
                        .foregroundStyle(balance < 0 ? Color.danger : Color.ink)
                        .layoutPriority(1)
                }
                HStack(spacing: 8) {
                    MooneeProgressBar(progress: progress, tint: level.fill)
                    PercentChip(percent: percent, level: level)
                }
                HStack(spacing: 2) {
                    if let subtitle { Text(subtitle) }
                    Spacer(minLength: 4)
                    AmountText(spent, currency: currency, short: true)
                    Text(verbatim: "/")
                    AmountText(budget, currency: currency, short: true)
                }
                .font(.caption).foregroundStyle(Color.inkSecondary)
            }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.inkSecondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(Color.surface.opacity(0.85), in: .rect(cornerRadius: 20))
    }

    private var tile: some View {
        VStack(spacing: 6) {
            IconBadge(symbol: symbol, color: color, size: 40)
            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink).lineLimit(1).minimumScaleFactor(0.8)
            AmountText(balance, currency: currency)
                .font(.subheadline.weight(.bold))
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
        .padding(12)
        .frame(minWidth: 96)
        .background(Color.surface.opacity(0.85), in: .rect(cornerRadius: 18))
        .shadow(color: .brandDeep.opacity(0.06), radius: 8, y: 3)
    }
}
