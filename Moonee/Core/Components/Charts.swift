import SwiftUI
import Charts

/// Budget ring with the percent in the middle; turns orange at 80% and red past 100% (spec §E).
struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0.0

    private var level: BudgetLevel { BudgetLevel(progress: progress) }

    var body: some View {
        let value = min(max(shown, 0), 1)
        Chart {
            SectorMark(angle: .value("done", value), innerRadius: .ratio(0.78)).foregroundStyle(level.fill).cornerRadius(lineWidth)
            SectorMark(angle: .value("left", 1 - value), innerRadius: .ratio(0.78)).foregroundStyle(Color.track)
        }
        .chartLegend(.hidden)
        .overlay {
            HStack(spacing: 2) {
                if let s = level.symbol { Image(systemName: s).font(.caption) }
                Text("\(Int((progress * 100).rounded()))%").monospacedDigit()
            }
            .font(.title3.weight(.bold))
            .foregroundStyle(level == .normal ? Color.ink : level.text)
            .minimumScaleFactor(0.5)
            .padding(lineWidth + 4)
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            if reduceMotion { shown = progress } else { withAnimation(.easeOut(duration: 0.5)) { shown = progress } }
        }
        .onChange(of: progress) { _, p in shown = p }
        .accessibilityElement()
        .accessibilityLabel(Text("Budget used", tableName: "Components"))
        .accessibilityValue(Text("\(Int((progress * 100).rounded()))%"))
    }
}

/// Donut by jar or asset class. Legend and amounts are screen-specific, so the caller lays them out.
struct DonutChart<Center: View>: View {
    struct Slice: Identifiable {
        var id: String { label }
        let label: String
        let value: Double
        let color: Color
    }

    let slices: [Slice]
    @ViewBuilder var center: Center
    /// Touch a slice: it pops out, the rest fade, the centre names it (with a light tick).
    @State private var pick: Double?
    @State private var grow = 0.0

    var body: some View {
        let total = slices.map { max($0.value, 0) }.reduce(0, +)
        let selected = pick.flatMap { p in
            var running = 0.0
            return slices.first { running += max($0.value, 0); return p <= running }
        }
        Chart {
            ForEach(slices) { s in
                SectorMark(angle: .value(s.label, max(s.value, 0)), innerRadius: .ratio(0.64),
                           outerRadius: .ratio(selected?.id == s.id ? 1 : 0.93), angularInset: 1.5)
                    .cornerRadius(4)
                    .foregroundStyle(s.color.gradient)
                    .opacity(selected == nil || selected?.id == s.id ? 1 : 0.35)
                    .accessibilityLabel(s.label)
                    .accessibilityValue(percent(s))
            }
            // Sweep-in: an empty sector holds the part of the circle not drawn yet.
            if grow < 1 {
                SectorMark(angle: .value("rest", total * (1 - grow) / max(grow, 0.001)), innerRadius: .ratio(0.64))
                    .foregroundStyle(.clear)
                    .accessibilityHidden(true)
            }
        }
        .chartLegend(.hidden)
        .chartAngleSelection(value: $pick)
        .sensoryFeedback(.selection, trigger: selected?.id)
        .overlay {
            Group {
                if let selected {
                    VStack(spacing: 0) {
                        Text(selected.label).font(.caption).foregroundStyle(Color.inkSecondary).lineLimit(1)
                        Text(percent(selected)).font(.headline).foregroundStyle(Color.ink).monospacedDigit()
                    }
                    .minimumScaleFactor(0.6)
                } else {
                    center
                }
            }
            .padding(28)
            .allowsHitTesting(false)
        }
        .aspectRatio(1, contentMode: .fit)
        .growIn($grow)
    }

    private func percent(_ s: Slice) -> String {
        let total = slices.map { max($0.value, 0) }.reduce(0, +)
        return (total > 0 ? s.value / total : 0).formatted(.percent.precision(.fractionLength(0...1)))
    }
}

extension DonutChart where Center == EmptyView {
    init(slices: [Slice]) { self.init(slices: slices) { EmptyView() } }
}

/// Character + message for screens with no data yet (spec §E).
struct EmptyState<Action: View>: View {
    var mood: MooneeMood = .sleepy
    let title: String
    let message: String
    @ViewBuilder var action: Action

    var body: some View {
        // Like ContentUnavailableView, with Moonee in place of the symbol.
        VStack(spacing: 8) {
            MooneeCharacter(mood: mood).frame(height: 104).padding(.bottom, 4)
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Color.ink)
            Text(message).font(.subheadline).foregroundStyle(Color.inkSecondary)
            action.padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}

extension EmptyState where Action == EmptyView {
    init(mood: MooneeMood = .sleepy, title: String, message: String) {
        self.init(mood: mood, title: title, message: message) { EmptyView() }
    }
}
