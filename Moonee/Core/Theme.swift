import SwiftUI

extension Color {
    init(hex: Int) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

}

// MARK: - Tokens (spec "Lưu ý cho Design System" A). Screens use these, never hex.

extension ShapeStyle where Self == Color {
    // brand
    static var brandPrimary: Color { Color(hex: 0x22C55E) }      // pills, FAB, progress
    static var brandPrimaryLight: Color { Color(hex: 0x4ADE80) } // gradient top
    static var brandDeep: Color { Color(hex: 0x15803D) }         // green text/icons on white (5:1)
    static var brandMint: Color { Color(hex: 0xE7FBF1) }         // screen background
    static var brandMintSoft: Color { Color(hex: 0xDCFCE7) }     // chips, user bubble, saved banner
    static var brandYellow: Color { Color(hex: 0xFACC15) }       // coin, sparkles, hills
    static var ink: Color { Color(hex: 0x0A3824) }               // primary text
    static var inkSecondary: Color { Color(hex: 0x5B6B63) }      // secondary text (5.4:1 on white)
    static var track: Color { Color(hex: 0xE4E9E9) }             // empty progress track
    static var surface: Color { .white }                         // cards

    // semantic: never the only signal; pair with +/− or an icon (spec F)
    static var income: Color { Color(hex: 0x15803D) }
    static var expense: Color { Color(hex: 0x0A3824) }  // mockups show spending in ink with a "−"
    static var warning: Color { Color(hex: 0xF97316) }  // fills: ≥80% bars, worried states
    static var warningText: Color { Color(hex: 0xC2410C) } // warning on white text (5.2:1)
    static var danger: Color { Color(hex: 0xDC2626) }   // over budget, overdue, negative (4.8:1)
}

/// 12 jar colours. Checked in tests: every pair stays apart (ΔE ≥ 9) under normal,
/// protan, deutan and tritan vision, and none sits near brand green, warning or danger.
/// Default jars take 0…5 in spec order (essentials, investing, savings, growth, play, giving).
enum JarPalette {
    static let hex = [0xEAB308, 0x0D9488, 0x60A5FA, 0x9333EA, 0xF472B6, 0xA3E635,
                      0x4338CA, 0x22D3EE, 0x92400E, 0xE879F9, 0x64748B, 0xBE185D]
    static func color(_ index: Int) -> Color { Color(hex: hex[((index % hex.count) + hex.count) % hex.count]) }
}

extension Color {
    // ponytail: legacy names kept so files owned by other sessions still compile; new code uses the tokens above.
    static let mooneeGreen = Color.brandPrimary
    static let mooneeDark = Color.brandDeep
    static let mooneeInk = Color.ink
    static let mooneeYellow = Color.brandYellow
}

extension LinearGradient {
    /// The one green gradient of pills, FAB and primary buttons.
    static let brand = LinearGradient(colors: [.brandPrimaryLight, Color(hex: 0x16A34A)], startPoint: .top, endPoint: .bottom)
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
            LinearGradient(colors: [.brandMint, Color(hex: 0xF6FCF9)], startPoint: .top, endPoint: .bottom)
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
                hill(w, h, peak: 0.3, height: 0.35).fill(LinearGradient(colors: [.brandPrimaryLight.opacity(0.7), .mooneeGreen.opacity(0.5)], startPoint: .top, endPoint: .bottom))
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
                                Capsule().fill(LinearGradient.brand)
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
            .background(LinearGradient.brand, in: .capsule)
            .shadow(color: .mooneeGreen.opacity(0.35), radius: 10, y: 5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
