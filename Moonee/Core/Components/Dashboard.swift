import SwiftUI

// Dashboard language shared by Overview, Budget, Watchlist and Report (round 4, owner feedback "too plain").
// Charts follow the Mebius chart kit: ghost-grey bars with one highlighted bar, gradient areas, capsule ends,
// a dashed reference line with a pill label, tick meters, and a white callout with a coloured tick per series.
// Motion follows Animos' presets: cards rise in one after another ("stack"), charts grow from the baseline,
// numbers roll. Everything is off with Reduce Motion.

extension Animation {
    /// Cards rising in (Animos "Natural": smooth, a hint of overshoot).
    static let reveal = Animation.smooth(duration: 0.55, extraBounce: 0.06)
    /// Bars, lines and rings growing from zero.
    static let chartGrow = Animation.spring(duration: 0.9, bounce: 0.12)
}

/// Rises and fades in once, `order` × 60 ms after the screen appears.
private struct Reveal: ViewModifier {
    let order: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        let on = shown || reduceMotion
        content
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 18)
            .scaleEffect(on ? 1 : 0.97, anchor: .top)
            .onAppear {
                guard !shown, !reduceMotion else { return }
                withAnimation(.reveal.delay(Double(order) * 0.06)) { shown = true }
            }
    }
}

/// Animates `value` 0 → 1 once on appear; 1 straight away with Reduce Motion. Charts multiply their values by it.
private struct GrowIn: ViewModifier {
    @Binding var value: Double
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.onAppear {
            guard value < 1 else { return }
            if reduceMotion { value = 1 } else { withAnimation(.chartGrow.delay(delay)) { value = 1 } }
        }
    }
}

extension View {
    /// Staggered entrance for a dashboard card.
    func reveal(_ order: Int = 0) -> some View { modifier(Reveal(order: order)) }

    /// Drives a chart's 0 → 1 grow factor.
    func growIn(_ value: Binding<Double>, delay: Double = 0.15) -> some View { modifier(GrowIn(value: value, delay: delay)) }
}

/// "↗ +12%" in a tinted capsule (Mebius KPI pill). Arrow and sign, so colour is never the only cue (spec F).
struct ChangeBadge: View {
    let percent: Int
    /// Income going up is good; spending going up is not.
    var upIsGood = false

    var body: some View {
        let color: Color = percent == 0 ? .inkSecondary : (percent > 0) == upIsGood ? .brandDeep : .warningText
        HStack(spacing: 2) {
            Image(systemName: percent > 0 ? "arrow.up.right" : percent < 0 ? "arrow.down.right" : "equal")
            Text(verbatim: "\(percent > 0 ? "+" : "")\(percent)%")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(percent)))
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: .capsule)
        .fixedSize()
    }
}

/// Card title with a Settings-style filled icon tile.
struct CardHeader<Trailing: View>: View {
    let title: Text
    let symbol: String
    var tint: Color = .brandPrimary
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: .rect(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            title.font(.sectionTitle).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(title: Text, symbol: String, tint: Color = .brandPrimary) {
        self.init(title: title, symbol: symbol, tint: tint) { EmptyView() }
    }
}

/// The floating label of a selected chart point: a title, then one amount per series with its colour tick.
struct ChartCallout: View {
    struct Row: Identifiable {
        let id = UUID()
        let color: Color
        let amount: Int
    }

    let title: String
    let rows: [Row]
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Color.inkSecondary)
            ForEach(rows) { r in
                HStack(spacing: 6) {
                    Capsule().fill(r.color).frame(width: 3, height: 12)
                    AmountText(r.amount, currency: currency).font(.footnote.weight(.semibold)).foregroundStyle(Color.ink)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.surface, in: .rect(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .fixedSize()
    }
}

/// Small text pill on a chart's reference line ("Avg 120k").
struct ChartPill: View {
    let text: String
    var color: Color = .inkSecondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color, in: .capsule)
            .fixedSize()
    }
}

/// Budget used as a row of capsule ticks (Mebius "Budget" / "maturity" cards). Ticks fill one after another.
struct TickMeter: View {
    let progress: Double
    let color: Color
    var count = 32
    var height: CGFloat = 28
    @State private var grow = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let filled = Int((min(max(progress, 0), 1) * grow * Double(count)).rounded())
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i < filled ? AnyShapeStyle(color.gradient) : AnyShapeStyle(Color.track))
                    .frame(height: height)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25).delay(Double(i) * 0.015), value: filled)
            }
        }
        .growIn($grow)
        .accessibilityHidden(true)
    }
}

/// Activity-style ring: a pale track and a round-capped arc that sweeps in, with a view in the middle.
struct SweepRing<Center: View>: View {
    let progress: Double
    let color: Color
    var lineWidth: CGFloat = 8
    @ViewBuilder var center: Center
    @State private var grow = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1) * grow)
                .stroke(color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center
        }
        .padding(lineWidth / 2)
        .growIn($grow, delay: 0.25)
    }
}

/// Moonee with a short line: the Overview note, the Budget month-closed cheer. Small and static unless `animated`.
struct MooneeNoteCard: View {
    let mood: MooneeMood
    let text: String
    var title: String?
    var animated = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            MooneeCharacter(mood: mood, animated: animated)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                if let title { Text(title).font(.rowTitle).foregroundStyle(Color.ink) }
                Text(text).font(.bodyText).foregroundStyle(title == nil ? Color.ink : Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// An amount whose digits roll: up from zero when it first appears (Animos counter), and to each new value.
struct RollingAmount: View {
    let minor: Int
    let currency: String
    var plus = false
    @State private var shown: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ minor: Int, currency: String, plus: Bool = false) {
        self.minor = minor
        self.currency = currency
        self.plus = plus
    }

    var body: some View {
        let value = shown ?? (reduceMotion ? minor : 0)
        AmountText(value, currency: currency, plus: plus)
            .contentTransition(.numericText(value: Double(value)))
            .onAppear { roll(to: minor) }
            .onChange(of: minor) { _, m in roll(to: m) }
    }

    private func roll(to m: Int) {
        if reduceMotion { shown = m } else { withAnimation(.smooth(duration: 0.6)) { shown = m } }
    }
}

/// Week / Month / Year on dashboards: a frosted capsule track with a deep-green pill that slides to the choice
/// (Animos "Snappy"), a light tick on change. White on the pill stays ≥ 4:1 (brandAction → brandDeep).
struct CapsuleSwitcher<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { value, title in
                let on = value == selection
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.32)) { selection = value }
                } label: {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(on ? Color.white : Color.inkSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background {
                            if on {
                                Capsule()
                                    .fill(LinearGradient(colors: [.brandAction, .brandDeep], startPoint: .top, endPoint: .bottom))
                                    .shadow(color: Color.brandDeep.opacity(0.3), radius: 6, y: 3)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: .capsule)
        .background(Color.surface.opacity(0.6), in: .capsule)
        .overlay(Capsule().strokeBorder(Color.brandPrimary.opacity(0.15)))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Lays children out in a row, or in a column at accessibility text sizes.
struct AdaptiveStack<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        let layout = size.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
                                              : AnyLayout(HStackLayout(alignment: .top, spacing: spacing))
        layout { content }
    }
}
