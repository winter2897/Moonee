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
    static var brandAction: Color { Color(hex: 0x16A34A) }       // button tint: white label stays readable (3.3:1, bold text)
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

// MARK: - Type scale (UI review 2026-11-05, measured on the mockups). Screens use only these.
// All follow Dynamic Type. Sizes are at the default (Large) setting.

extension Font {
    /// "Moonee" in the screen header, 20 bold.
    static let screenTitle = Font.title3.bold()
    /// Subtitle pill under the header title, 13 medium.
    static let headerPill = Font.footnote.weight(.medium)
    /// Amount on a summary card (spent today, a card's net worth), 20 bold. The big total uses `.heroAmountFont()`.
    static let cardAmount = Font.title3.bold()
    /// "Chào bạn!" over Moonee's note, 17 bold.
    static let greeting = Font.headline.bold()
    /// Card and section titles, 16 semibold.
    static let sectionTitle = Font.callout.weight(.semibold)
    /// List row titles, 15 semibold.
    static let rowTitle = Font.subheadline.weight(.semibold)
    /// Body text: chat bubbles, notes, 15.
    static let bodyText = Font.subheadline
    /// Row subtitles and secondary lines, 13.
    static let secondaryText = Font.footnote
    // caption (%, meta, tab labels) is the system `.caption`, 12.
    /// Chips, pills and small buttons, 13 medium.
    static let chip = Font.footnote.weight(.medium)
}

extension Font {
    /// The one big amount of a screen (budget total, net worth, wallet total): system `.title` (28), bold rounded.
    static let heroAmount = Font.system(.title, design: .rounded, weight: .bold)
}

extension View {
    /// Same as `.font(.heroAmount)`; kept for existing call sites.
    func heroAmountFont() -> some View { font(.heroAmount) }
}

extension LinearGradient {
    /// The one green gradient of pills, FAB and primary buttons.
    static let brand = LinearGradient(colors: [.brandPrimaryLight, Color(hex: 0x16A34A)], startPoint: .top, endPoint: .bottom)
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

/// Soft mint and yellow hills behind the hero (S4's chat hills, approved by the owner): each hill pales toward its foot,
/// and the whole fades out at the bottom, so there is no hard edge. Place it from the character's coin height downward.
struct Hills: View {
    var body: some View {
        Canvas { ctx, size in
            let (w, h) = (size.width, size.height)
            func hill(_ color: Color, _ build: (inout Path) -> Void) {
                var p = Path()
                build(&p)
                p.closeSubpath()
                // Each hill is deeper at its crest and pales toward its foot, like the mockup's soft mounds.
                let top = p.boundingRect.minY
                ctx.fill(p, with: .linearGradient(Gradient(colors: [color, color.opacity(0.25)]),
                                                  startPoint: .init(x: 0, y: top), endPoint: .init(x: 0, y: h)))
            }
            // Far mint hill: high on the left, rolling down behind the character.
            hill(Color.brandPrimaryLight.opacity(0.4)) { p in
                p.move(to: .init(x: 0, y: h))
                p.addLine(to: .init(x: 0, y: h * 0.12))
                p.addCurve(to: .init(x: w * 0.68, y: h * 0.78), control1: .init(x: w * 0.16, y: h * -0.02), control2: .init(x: w * 0.4, y: h * 0.62))
                p.addLine(to: .init(x: w * 0.68, y: h))
            }
            // Warm yellow hill rising to the right edge.
            hill(Color.brandYellow.opacity(0.5)) { p in
                p.move(to: .init(x: w * 0.42, y: h))
                p.addCurve(to: .init(x: w, y: h * 0.14), control1: .init(x: w * 0.66, y: h * 0.74), control2: .init(x: w * 0.84, y: h * 0.16))
                p.addLine(to: .init(x: w, y: h))
            }
            // A second, lighter mint wave across the screen.
            hill(Color.brandPrimaryLight.opacity(0.22)) { p in
                p.move(to: .init(x: 0, y: h))
                p.addLine(to: .init(x: 0, y: h * 0.32))
                p.addCurve(to: .init(x: w, y: h * 0.58), control1: .init(x: w * 0.3, y: h * 0.2), control2: .init(x: w * 0.6, y: h * 0.72))
                p.addLine(to: .init(x: w, y: h))
            }
            // Pale ground the character stands on.
            hill(Color.white.opacity(0.7)) { p in
                p.move(to: .init(x: 0, y: h))
                p.addLine(to: .init(x: 0, y: h * 0.5))
                p.addCurve(to: .init(x: w, y: h * 0.6), control1: .init(x: w * 0.35, y: h * 0.42), control2: .init(x: w * 0.62, y: h * 0.78))
                p.addLine(to: .init(x: w, y: h))
            }
        }
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// White card on the mint background, like an inset-grouped list section: 16 pt padding, 20 pt continuous corners,
    /// a hairline shadow only. Rows inside use `.card(padding: 0)` and their own 16 pt insets.
    func card(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(Color.surface.opacity(0.92), in: .rect(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
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
    /// 30 pt, like Settings' row icons; larger only for a hero (jar detail).
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.15), in: .circle)
    }
}

/// Segmented control (Chi tiêu/Thu nhập, Tuần/Tháng/Năm): the system `Picker(.segmented)`, kept as a type so call sites stay short.
struct PillPicker<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        Picker(selection: $selection) {
            ForEach(options, id: \.0) { value, title in Text(title).tag(value) }
        } label: { EmptyView() }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// Primary action: the system `.borderedProminent` capsule, `.large`, full width, brand green.
/// Same as `.buttonStyle(.borderedProminent).controlSize(.large).buttonBorderShape(.capsule).tint(.brandAction)`.
struct MooneeButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.fontWeight(.semibold).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(.brandAction)
    }
}

/// Small action ("Undo", "Paid", "Download"): the system `.bordered` capsule, `.small`, brand green;
/// `filled: true` is `.borderedProminent` ("Done").
struct OutlinePillStyle: PrimitiveButtonStyle {
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        // One line: a small action never wraps; the content beside it reflows instead.
        let button = Button(role: configuration.role, action: configuration.trigger) { configuration.label.fontWeight(.semibold).lineLimit(1) }
            .fixedSize()
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(.brandAction)
        if filled { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
    }
}
