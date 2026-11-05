import SwiftUI

extension Color {
    init(hex: Int) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static let mooneeGreen = Color(hex: 0x22C55E)
    static let mooneeDark = Color(hex: 0x15803D)
    static let mooneeInk = Color(hex: 0x0F3D2E)
    static let mooneeYellow = Color(hex: 0xFACC15)
}

extension Int {
    /// 250000 → "250.000 đ"
    var vnd: String { grouped + " đ" }
    var grouped: String { formatted(.number.locale(Locale(identifier: "vi_VN"))) }
}

/// Mint gradient with soft yellow/green glows, as in the mockups.
struct MooneeBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0xE6F6EB), Color(hex: 0xF5FBF7)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [.mooneeYellow.opacity(0.22), .clear], center: .bottomLeading, startRadius: 0, endRadius: 340)
            RadialGradient(colors: [.mooneeGreen.opacity(0.14), .clear], center: .topTrailing, startRadius: 0, endRadius: 300)
        }
        .ignoresSafeArea()
    }
}

/// Green/yellow hills used on the hero cards.
struct Hills: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                hill(w, h, peak: 0.55, height: 0.55).fill(LinearGradient(colors: [.mooneeYellow, .mooneeYellow.opacity(0.6)], startPoint: .trailing, endPoint: .leading))
                hill(w, h, peak: 0.3, height: 0.35).fill(LinearGradient(colors: [Color(hex: 0x86EFAC), .mooneeGreen.opacity(0.5)], startPoint: .top, endPoint: .bottom))
            }
        }
        .allowsHitTesting(false)
    }

    private func hill(_ w: CGFloat, _ h: CGFloat, peak: CGFloat, height: CGFloat) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: h))
            p.addCurve(to: CGPoint(x: w, y: h * (1 - height)),
                       control1: CGPoint(x: w * peak, y: h * (1 - height * 0.2)),
                       control2: CGPoint(x: w * 0.75, y: h * (1 - height * 1.3)))
            p.addLine(to: CGPoint(x: w, y: h))
            p.closeSubpath()
        }
    }
}

extension View {
    /// Frosted white card.
    func card(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(.white.opacity(0.78), in: .rect(cornerRadius: 22))
            .shadow(color: .mooneeDark.opacity(0.08), radius: 14, y: 6)
    }

    /// Standard tab screen: scroll + background + large title.
    func mooneeScreen(_ title: String) -> some View {
        ScrollView { self.padding(.horizontal, 16).padding(.bottom, 24) }
            .background(MooneeBackground())
            .navigationTitle(title)
    }
}

/// Rounded icon tile, e.g. category icons.
struct IconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.15), in: .circle)
    }
}

/// Pill segmented control (Chi tiêu/Thu nhập, Tuần/Tháng/Năm).
struct PillPicker<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.0) { value, title in
                Button { withAnimation(.snappy) { selection = value } } label: {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(selection == value ? .white : .mooneeInk)
                        .background {
                            if selection == value {
                                Capsule().fill(LinearGradient(colors: [.mooneeGreen, .mooneeDark], startPoint: .top, endPoint: .bottom))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.white.opacity(0.7), in: .capsule)
    }
}

/// Primary green capsule button style.
struct MooneeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(LinearGradient(colors: [.mooneeGreen, .mooneeDark], startPoint: .top, endPoint: .bottom), in: .capsule)
            .shadow(color: .mooneeGreen.opacity(0.35), radius: 10, y: 5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
