import Foundation
import SwiftUI
import Testing
@testable import Moonee

struct DesignSystemTests {
    @Test func budgetLevels() {
        #expect(BudgetLevel(balance: 2_000, spent: 500, budget: 1_000) == .normal)
        #expect(BudgetLevel(balance: 200, spent: 800, budget: 1_000) == .warning)
        #expect(BudgetLevel(balance: -100, spent: 1_100, budget: 1_000) == .over)
        #expect(BudgetLevel(balance: -100, spent: 300, budget: 1_000) == .negative) // carried-over deficit
        #expect(BudgetLevel(spent: 0, budget: 0) == .normal)
        #expect(BudgetLevel(spent: 1, budget: 0) == .over)
        #expect(BudgetLevel(progress: 0.79) == .normal)
        #expect(BudgetLevel(progress: 0.8) == .warning)
        #expect(BudgetLevel(progress: 1.01) == .over)
    }

    @Test func billStatus() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 23))!
        let day = { (d: Int) in cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: 1))! }
        #expect(BillStatus(due: day(8), paid: false, now: now, calendar: cal) == .upcoming(days: 3))
        #expect(BillStatus(due: day(5), paid: false, now: now, calendar: cal) == .today)
        #expect(BillStatus(due: day(3), paid: false, now: now, calendar: cal) == .overdue(days: 2))
        #expect(BillStatus(due: day(3), paid: true, now: now, calendar: cal) == .paid)
    }

    @Test func amountFormat() {
        let vi = Locale(identifier: "vi_VN"), en = Locale(identifier: "en_US")
        // ICU puts a no-break space before "₫"; compare with plain spaces.
        func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ") }
        #expect(plain(AmountFormat.string(1_250_000, "VND", locale: vi)) == "1.250.000 ₫")
        #expect(plain(AmountFormat.string(1_250_000, "VND", short: true, locale: vi)) == "1,25tr")
        #expect(plain(AmountFormat.string(850_000, "VND", short: true, locale: vi)) == "850k")
        #expect(plain(AmountFormat.string(15_000, "VND", plus: true, locale: vi)) == "+15.000 ₫")
        #expect(plain(AmountFormat.string(-65_000, "VND", locale: vi)) == "-65.000 ₫")
        #expect(plain(AmountFormat.string(19_842, "USD", locale: en)) == "$198.42")
        #expect(plain(AmountFormat.string(1_250_000, "VND", short: true, locale: en)) == "1.25M")
        #expect(AmountFormat.spoken(1_250_000, "VND", locale: vi).hasPrefix("một triệu hai trăm năm mươi nghìn"))
    }

    /// Jar colours stay apart for colour-blind users and away from semantic colours (spec §A).
    @Test func jarPaletteIsColourBlindSafe() {
        let semantic: [Color] = [.brandPrimary, .income, .warning, .danger]
        let jars = JarPalette.hex.map(Self.rgb)
        let sem = semantic.map(Self.rgb)
        #expect(JarPalette.hex.count == 12)
        for i in jars.indices {
            for j in jars.indices where j > i {
                #expect(Self.minDeltaE(jars[i], jars[j]) >= 9, "jar \(i + 1) vs jar \(j + 1)")
            }
            for s in sem.indices {
                #expect(Self.minDeltaE(jars[i], sem[s]) >= 9, "jar \(i + 1) vs semantic \(s)")
            }
        }
    }

    // MARK: colour math (sRGB → simulated dichromacy, Machado 2009 → CIELAB ΔE76)

    static func rgb(_ hex: Int) -> [Double] { [Double((hex >> 16) & 255), Double((hex >> 8) & 255), Double(hex & 255)].map { $0 / 255 } }

    static func rgb(_ color: Color) -> [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b].map(Double.init)
    }

    static let simulations: [[[Double]]] = [
        [[1, 0, 0], [0, 1, 0], [0, 0, 1]],
        [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]], // protan
        [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]],  // deutan
        [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900]], // tritan
    ]

    static func lab(_ srgb: [Double], _ m: [[Double]]) -> [Double] {
        let l = srgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let c = m.map { min(1, max(0, $0[0] * l[0] + $0[1] * l[1] + $0[2] * l[2])) }
        let x = (0.4124 * c[0] + 0.3576 * c[1] + 0.1805 * c[2]) / 0.95047
        let y = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
        let z = (0.0193 * c[0] + 0.1192 * c[1] + 0.9505 * c[2]) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))]
    }

    static func minDeltaE(_ a: [Double], _ b: [Double]) -> Double {
        simulations.map { m in
            let p = lab(a, m), q = lab(b, m)
            return sqrt(zip(p, q).map { ($0 - $1) * ($0 - $1) }.reduce(0, +))
        }.min()!
    }
}

/// Animated frames are scaled by their mean fill, so the hero shows the same body size with or without Reduce Motion.
@MainActor @Test func animationFillIsMeasured() {
    for mood in MooneeMood.allCases {
        guard let anim = MooneeAnimation.load(mood) else { Issue.record("no animation for \(mood)"); continue }
        #expect((0.6...1).contains(anim.meanFill), "\(mood): \(anim.meanFill)")
    }
}
