import SwiftUI

/// Floating tab bar of the mockups: 4 tabs around a raised green (+) that opens the Moonee chat.
/// Use it in place of the system bar: overlay it on the `TabView(selection:)` and put `.mooneeTabContent(barHeight:)` on each tab's content
/// (a `TabView`-level `safeAreaInset` does not reach the tabs' scroll views).
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
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let half = items.count / 2
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                if i == half { Color.clear.frame(width: 64) }
                tabButton(items[i])
            }
        }
        // 60 pt capsule; the selection pill sits 4 pt inside it, so their ends stay concentric.
        .padding(4)
        .frame(minHeight: 60)
        .background(Color.surface, in: .capsule)
        .shadow(color: .brandDeep.opacity(0.10), radius: 16, y: 6)
        .overlay(alignment: .top) {
            Button(action: onPlus) {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(LinearGradient.brand, in: .circle)
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 3))
                    .shadow(color: .brandPrimary.opacity(0.45), radius: 12, y: 5)
            }
            .buttonStyle(FABStyle())
            .offset(y: -8)
            .accessibilityLabel(Text("Add with Moonee", tableName: "Components"))
        }
        .padding(.horizontal, 16)
    }

    private func tabButton(_ item: Item) -> some View {
        let selected = item.tab == selection
        return Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { selection = item.tab }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.symbol).font(.system(size: 20, weight: selected ? .semibold : .regular))
                // At accessibility sizes the labels can't fit 4 across: icons only, with the Large Content Viewer on long press.
                if !typeSize.isAccessibilitySize {
                    Text(item.title).font(.caption.weight(selected ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(selected ? Color.brandDeep : Color.ink.opacity(0.75))
            .frame(maxWidth: .infinity, minHeight: 52)
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
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer { Label(item.title, systemImage: item.symbol) }
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

extension View {
    /// Per tab, under the floating `MooneeTabBar`: keeps the last row scrollable above the bar and
    /// (`contentMargins`, because a `safeAreaInset`/`safeAreaPadding` here doesn't reach through the tab's NavigationStack)
    /// fades content out under the status bar on screens that hide the navigation bar.
    /// The margin also reaches horizontal ScrollViews; if one grows a gap under it, add `.contentMargins(.bottom, 0, for: .scrollContent)` to it.
    func mooneeTabContent(barHeight: CGFloat) -> some View {
        self
            .toolbarVisibility(.hidden, for: .tabBar)
            .contentMargins(.bottom, barHeight, for: .scrollContent)
            .statusBarScrim()
    }

    /// Mint fade under the status bar / Dynamic Island so scrolled text doesn't collide with the clock.
    func statusBarScrim() -> some View {
        overlay(alignment: .top) {
            Color.clear.frame(height: 14)
                .background {
                    LinearGradient(stops: [.init(color: .brandMint, location: 0), .init(color: .brandMint.opacity(0.95), location: 0.7),
                                           .init(color: .brandMint.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .top)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
