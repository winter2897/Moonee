import SwiftUI

/// Floating tab bar of the mockups: 4 tabs around a raised green (+) that opens the Moonee chat.
/// Use it in place of the system bar: `TabView(selection:)` + `.toolbarVisibility(.hidden, for: .tabBar)` on each tab's content + `.safeAreaInset(edge: .bottom)`.
struct MooneeTabBar<Tab: Hashable>: View {
    struct Item {
        let tab: Tab
        let title: String
        let symbol: String
    }

    /// Four items; the (+) sits between the second and third.
    let items: [Item]
    @Binding var selection: Tab
    let onPlus: () -> Void

    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let half = items.count / 2
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                if i == half { Color.clear.frame(width: 76) }
                tabButton(items[i])
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 72)
        .background(Color.surface, in: .rect(cornerRadius: 30))
        .shadow(color: .brandDeep.opacity(0.10), radius: 16, y: 6)
        .overlay(alignment: .top) {
            Button(action: onPlus) {
                Image(systemName: "plus")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 66, height: 66)
                    .background(LinearGradient.brand, in: .circle)
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 4))
                    .shadow(color: .brandPrimary.opacity(0.45), radius: 14, y: 6)
            }
            .buttonStyle(FABStyle())
            .offset(y: -10)
            .accessibilityLabel(Text("Add with Moonee", tableName: "Components"))
        }
        .padding(.horizontal, 16)
    }

    private func tabButton(_ item: Item) -> some View {
        let selected = item.tab == selection
        return Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { selection = item.tab }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: item.symbol).font(.system(size: 22, weight: selected ? .semibold : .regular))
                Text(item.title).font(.caption.weight(selected ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(selected ? Color.brandDeep : Color.ink.opacity(0.75))
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(.rect)
            .background {
                // Selected tab sits on an interactive Liquid Glass pill that slides to the tapped tab.
                if selected {
                    Capsule()
                        .fill(Color.brandPrimary.opacity(0.10))
                        .glassEffect(.regular.tint(Color.brandPrimary.opacity(0.12)).interactive(), in: .capsule)
                        .matchedGeometryEffect(id: "selection", in: glass)
                }
            }
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Pressed (+): sinks a little and darkens.
private struct FABStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
