import AppIntents
import SwiftUI
import WidgetKit

// Spec §8. The numbers come from `WidgetSnapshot` (written by the app from `BudgetFacts`); nothing is computed here
// beyond rolling the snapshot over midnight and month ends. Strings: Widgets.xcstrings.

@main
struct MooneeWidgets: WidgetBundle {
    var body: some Widget {
        BudgetWidget()
        QuickAddWidget()
        LogTransactionControl()
    }
}

private func L(_ key: String.LocalizationValue) -> LocalizedStringResource { LocalizedStringResource(key, table: "Widgets") }

// MARK: - Timeline

struct BudgetEntry: TimelineEntry {
    let date: Date
    /// nil: the app has not written its numbers yet (installed, never opened since).
    let snapshot: WidgetSnapshot?
}

struct BudgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BudgetEntry { BudgetEntry(date: .now, snapshot: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (BudgetEntry) -> Void) {
        let now = Date.now
        completion(BudgetEntry(date: now, snapshot: WidgetSnapshot.load()?.at(now) ?? (context.isPreview ? .sample : nil)))
    }

    /// Now, and midnight (today's spend starts again); WidgetKit asks again within the hour.
    func getTimeline(in context: Context, completion: @escaping (Timeline<BudgetEntry>) -> Void) {
        let now = Date.now, snapshot = WidgetSnapshot.load()
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        let entries = [now, midnight].map { BudgetEntry(date: $0, snapshot: snapshot?.at($0)) }
        completion(Timeline(entries: entries, policy: .after(min(now.addingTimeInterval(3600), midnight))))
    }
}

extension WidgetSnapshot {
    /// The widget gallery's example: a month a third spent.
    static var sample: WidgetSnapshot {
        let code = Locale.current.currency?.identifier ?? "USD"
        let unit = Int(truncating: pow(10, AmountFormat.fractionDigits(code)) as NSDecimalNumber) * (AmountFormat.fractionDigits(code) == 0 ? 1000 : 1)
        return WidgetSnapshot(date: .now, currency: code, hidden: false, spentToday: 85 * unit, jars: [
            Jar(name: String(localized: "jar.essentials", table: "Widgets"), colorHex: 0xEAB308, budget: 5500 * unit, spent: 2100 * unit, balance: 3400 * unit),
            Jar(name: String(localized: "jar.play", table: "Widgets"), colorHex: 0xF472B6, budget: 1000 * unit, spent: 450 * unit, balance: 550 * unit),
            Jar(name: String(localized: "jar.growth", table: "Widgets"), colorHex: 0x9333EA, budget: 1000 * unit, spent: 200 * unit, balance: 800 * unit),
        ])
    }

    func money(_ minor: Int, short: Bool = false) -> String { hidden ? AmountFormat.mask : AmountFormat.string(minor, currency, short: short) }
    func spoken(_ minor: Int) -> String { hidden ? String(localized: "Balance hidden", table: "Widgets") : AmountFormat.spoken(minor, currency) }
}

// MARK: - Budget widget (Home small/medium, Lock Screen circular/rectangular/inline)

struct BudgetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "budget", provider: BudgetProvider()) { entry in
            BudgetWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackground() }
                .widgetURL(WidgetSnapshot.deepLink)
        }
        .configurationDisplayName(L("Left this month"))
        .description(L("What's left this month, today's spending and your top jars."))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

/// Mint like the app's screens. Light only (spec: widgets set their own colours).
struct WidgetBackground: View {
    var body: some View {
        LinearGradient(colors: [.brandMint, .white], startPoint: .top, endPoint: .bottom)
    }
}

struct BudgetWidgetView: View {
    let entry: BudgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let s = entry.snapshot {
            switch family {
            case .accessoryCircular: Circular(s: s)
            case .accessoryRectangular: Rectangular(s: s)
            case .accessoryInline: Text("\(s.money(s.left, short: true)) left", tableName: "Widgets")
            case .systemMedium:
                HStack(spacing: 16) {
                    Summary(s: s)
                    TopJars(s: s)
                }
            default: Summary(s: s)
            }
        } else {
            Empty()
        }
    }
}

private struct Summary: View {
    let s: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text("Left this month", tableName: "Widgets")
                    .font(.caption.weight(.semibold)).foregroundStyle(.inkSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image("moonee.happy").resizable().widgetAccentedRenderingMode(.fullColor).scaledToFit().frame(height: 26).accessibilityHidden(true)
            }
            Text(s.money(s.left))
                .font(.system(.title2, design: .rounded, weight: .bold)).monospacedDigit()
                .foregroundStyle(s.left < 0 ? Color.danger : .ink)
                .lineLimit(1).minimumScaleFactor(0.5)
                .accessibilityLabel(s.spoken(s.left))
            Bar(progress: s.progress, color: Bar.color(spent: s.spent, budget: s.budget, normal: .brandPrimary))
            Spacer(minLength: 0)
            Text("Spent today", tableName: "Widgets").font(.caption2).foregroundStyle(.inkSecondary)
            Text(s.money(s.spentToday))
                .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
                .accessibilityLabel(s.spoken(s.spentToday))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TopJars: View {
    let s: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(s.topJars.enumerated()), id: \.offset) { _, jar in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(jar.name).font(.caption.weight(.semibold)).foregroundStyle(.ink).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(s.money(jar.balance, short: true)).font(.caption).monospacedDigit()
                            .foregroundStyle(jar.balance < 0 && !s.hidden ? Color.danger : .inkSecondary)
                            .accessibilityLabel(s.spoken(jar.balance))
                    }
                    Bar(progress: jar.progress, color: Bar.color(spent: jar.spent, budget: jar.budget, normal: Color(hex: jar.colorHex)))
                }
            }
            Spacer(minLength: 0)
            Link(destination: WidgetSnapshot.deepLink) {
                Label { Text("Log a transaction", tableName: "Widgets") } icon: { Image(systemName: "plus") }
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(LinearGradient.brand, in: .capsule)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Bar: View {
    let progress: Double
    let color: Color

    /// Same signal as the app's jar cards: orange from 80 %, red when over.
    static func color(spent: Int, budget: Int, normal: Color) -> Color {
        spent > budget ? .danger : Double(spent) >= 0.8 * Double(budget) && spent > 0 ? .warning : normal
    }

    var body: some View {
        Capsule().fill(Color.track)
            .overlay(alignment: .leading) {
                GeometryReader { g in Capsule().fill(color).frame(width: g.size.width * progress) }
            }
            .frame(height: 6)
            .widgetAccentable()
            .accessibilityHidden(true)
    }
}

private struct Circular: View {
    let s: WidgetSnapshot

    var body: some View {
        if s.hidden {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "eye.slash").font(.title3)
            }
            .accessibilityLabel(String(localized: "Balance hidden", table: "Widgets"))
        } else {
            Gauge(value: s.progress) {
                Image(systemName: "wallet.bifold")
            } currentValueLabel: {
                Text(s.progress, format: .percent.precision(.fractionLength(0)))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .accessibilityLabel(Text("Spent this month", tableName: "Widgets"))
        }
    }
}

private struct Rectangular: View {
    let s: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Left this month", tableName: "Widgets").font(.caption2.weight(.semibold)).widgetAccentable()
            Text(s.money(s.left)).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                .accessibilityLabel(s.spoken(s.left))
            Text("Today \(s.money(s.spentToday, short: true))", tableName: "Widgets").font(.caption2).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Empty: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline: Text(verbatim: "Moonee")
        case .accessoryCircular, .accessoryRectangular: Image(systemName: "plus.bubble").font(.title2)
        default:
            VStack(spacing: 6) {
                Image("moonee.happy").resizable().widgetAccentedRenderingMode(.fullColor).scaledToFit().frame(height: 48)
                Text("Open Moonee to see your budget.", tableName: "Widgets")
                    .font(.caption).multilineTextAlignment(.center).foregroundStyle(.inkSecondary)
            }
        }
    }
}

// MARK: - Quick add (Home small, Lock Screen circular)

struct QuickAddWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "quickAdd", provider: QuickAddProvider()) { _ in
            QuickAddView()
                .containerBackground(for: .widget) { WidgetBackground() }
                .widgetURL(WidgetSnapshot.deepLink)
        }
        .configurationDisplayName(L("Log a transaction"))
        .description(L("Opens Moonee's chat to log what you spent."))
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

/// Nothing changes on this widget: one entry, never refreshed.
struct QuickAddProvider: TimelineProvider {
    func placeholder(in context: Context) -> BudgetEntry { BudgetEntry(date: .now, snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (BudgetEntry) -> Void) { completion(placeholder(in: context)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<BudgetEntry>) -> Void) {
        completion(Timeline(entries: [placeholder(in: context)], policy: .never))
    }
}

struct QuickAddView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .accessoryCircular {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "plus").font(.title.weight(.bold))
            }
            .accessibilityLabel(Text("Log a transaction", tableName: "Widgets"))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image("moonee.happy").resizable().widgetAccentedRenderingMode(.fullColor).scaledToFit().frame(height: 44).accessibilityHidden(true)
                Spacer(minLength: 0)
                Text("Tell Moonee what you spent.", tableName: "Widgets")
                    .font(.caption).foregroundStyle(.inkSecondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Label { Text("Log a transaction", tableName: "Widgets").lineLimit(1).minimumScaleFactor(0.7) } icon: { Image(systemName: "plus") }
                    .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(LinearGradient.brand, in: .capsule)
                    .widgetAccentable()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Control Center / Lock Screen control (iOS 18+)

struct LogTransactionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "logTransaction") {
            ControlWidgetButton(action: OpenChatIntent()) {
                Label { Text("Log a transaction", tableName: "Widgets") } icon: { Image(systemName: "plus.bubble.fill") }
            }
        }
        .displayName(L("Log a transaction"))
        .description(L("Opens Moonee's chat to log what you spent."))
    }
}

