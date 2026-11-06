import SwiftUI

/// Header of every tab (mockups): optional circle button · "Moonee ✨" over a subtitle pill · optional circle button.
///
///     MooneeHeader(Text("Budget & jars", tableName: "Budget")) {
///         Button(action: showStats) { HeaderCircle("chart.bar") }.accessibilityLabel(…)
///     } trailing: {
///         Menu { … } label: { HeaderCircle("ellipsis") }.accessibilityLabel(…)
///     }
///
/// Each side is a 44 pt slot, so the title stays centred with one button or none.
struct MooneeHeader<Leading: View, Trailing: View>: View {
    let subtitle: Text
    let leading: Leading
    let trailing: Trailing

    init(_ subtitle: Text, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.subtitle = subtitle
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Color.clear.frame(width: 44, height: 44).overlay { leading } // a fixed slot, even for EmptyView
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Text(verbatim: "Moonee").font(.screenTitle).foregroundStyle(Color.brandDeep)
                    Image(systemName: "sparkles").font(.subheadline.weight(.semibold)).foregroundStyle(Color.brandYellow)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "Moonee"))
                .accessibilityAddTraits(.isHeader)
                subtitle
                    .font(.headerPill)
                    .foregroundStyle(Color.brandDeep)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, 12).padding(.vertical, 3)
                    .background(Color.brandMintSoft, in: .capsule)
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
            Color.clear.frame(width: 44, height: 44).overlay { trailing } // a fixed slot, even for EmptyView
        }
    }
}

extension MooneeHeader where Leading == EmptyView {
    init(_ subtitle: Text, @ViewBuilder trailing: () -> Trailing) {
        self.init(subtitle, leading: { EmptyView() }, trailing: trailing)
    }
}

extension MooneeHeader where Leading == EmptyView, Trailing == EmptyView {
    init(_ subtitle: Text) {
        self.init(subtitle, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// Label for a header button: a 36 pt Liquid Glass circle (like a toolbar button) inside a 44 pt touch target.
/// Use as the label of a `Button`, `Menu` or `NavigationLink`, and give that an `accessibilityLabel`.
struct HeaderCircle: View {
    let symbol: String
    init(_ symbol: String) { self.symbol = symbol }

    var body: some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .imageScale(.small)
            .dynamicTypeSize(...DynamicTypeSize.xLarge) // the circle is fixed; the Large Content Viewer covers bigger sizes
            .foregroundStyle(Color.ink)
            .frame(width: 36, height: 36)
            .glassEffect(.regular.interactive(), in: .circle)
            .frame(width: 44, height: 44)
            .contentShape(.circle)
    }
}
