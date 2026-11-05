#if DEBUG
import SwiftUI

/// Every design-system component in every state, for review (Debug builds only; Tài khoản → Component Gallery).
struct ComponentGallery: View {
    enum Section: String, CaseIterable, Identifiable {
        case colors = "Colours", type = "Type", header = "Header", character = "Moonee", money = "Amounts", tabBar = "Tab bar", jars = "Jars",
             bills = "Bills", chat = "Chat", input = "Input", charts = "Charts", empty = "Empty"
        var id: String { rawValue }
    }

    @State private var section = Section.colors
    @State private var hidden = false
    @State private var largeText = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Section.allCases) { s in
                        Button(s.rawValue) { section = s }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).frame(minHeight: 36)
                            .foregroundStyle(section == s ? Color.white : Color.ink)
                            .background(section == s ? AnyShapeStyle(LinearGradient.brand) : AnyShapeStyle(Color.surface), in: .capsule)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .contentMargins(.bottom, 0, for: .scrollContent) // undo the tab bar clearance on a horizontal row
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(.horizontal, 16).padding(.bottom, 40)
            }
            .environment(\.balanceHidden, hidden)
            .dynamicTypeSize(largeText ? .accessibility2 : .large)
        }
        .background(MooneeBackground())
        .navigationTitle("Component Gallery")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Hide balances", isOn: $hidden)
                    Toggle("Large text (AX2)", isOn: $largeText)
                } label: { Image(systemName: "slider.horizontal.3") }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .colors: colors
        case .type: typeScale
        case .header: header
        case .character: character
        case .money: money
        case .tabBar: tabBar
        case .jars: jars
        case .bills: bills
        case .chat: chat
        case .input: input
        case .charts: charts
        case .empty: EmptyState(mood: .sleepy, title: "Chưa có giao dịch nào", message: "Nhắn cho Moonee “ăn trưa 45k” để ghi khoản đầu tiên nhé.") {
                Button("Ghi giao dịch") {}.buttonStyle(MooneeButtonStyle()).padding(.top, 8)
            }.card()
        }
    }

    // MARK: sections

    private var colors: some View {
        Group {
            title("Brand")
            swatches([("brandPrimary", .brandPrimary), ("brandPrimaryLight", .brandPrimaryLight), ("brandDeep", .brandDeep), ("brandMint", .brandMint),
                      ("brandMintSoft", .brandMintSoft), ("brandYellow", .brandYellow), ("ink", .ink), ("inkSecondary", .inkSecondary), ("track", .track)])
            title("Semantic")
            swatches([("income", .income), ("expense", .expense), ("warning", .warning), ("warningText", .warningText), ("danger", .danger)])
            title("Jar palette (12)")
            swatches(JarPalette.hex.indices.map { ("jar.\($0 + 1)", JarPalette.color($0)) })
            title("Buttons")
            Button("Lưu giao dịch") {}.buttonStyle(MooneeButtonStyle())
            PillPicker(options: [(0, "Tuần"), (1, "Tháng"), (2, "Năm")], selection: .constant(1))
        }
    }

    private var typeScale: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("screenTitle 20 bold").font(.screenTitle)
            Text("headerPill 13 medium").font(.headerPill)
            AmountText(6_450_000, currency: "VND").heroAmountFont()
            Text("heroAmountFont() 26 bold rounded").font(.caption).foregroundStyle(Color.inkSecondary)
            Text("cardAmount 20 bold").font(.cardAmount)
            Text("greeting 17 bold").font(.greeting)
            Text("sectionTitle 16 semibold").font(.sectionTitle)
            Text("rowTitle 15 semibold").font(.rowTitle)
            Text("bodyText 15").font(.bodyText)
            Text("secondaryText 13").font(.secondaryText)
            Text("caption 12 (system)").font(.caption)
            Text("chip 13 medium").font(.chip)
        }
        .foregroundStyle(Color.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var header: some View {
        VStack(spacing: 18) {
            VStack(spacing: 0) {
                MooneeHeader(Text(verbatim: "Trợ lý tài chính AI của bạn")) {
                    Button {} label: { HeaderCircle("clock") }.accessibilityLabel("Transactions")
                } trailing: {
                    Menu { Button("Ẩn số dư") {} } label: { HeaderCircle("ellipsis") }.accessibilityLabel("More")
                }
                MooneeHero(mood: .greeting)
            }
            VStack(spacing: 0) {
                MooneeHeader(Text(verbatim: "Ngân sách & các lọ")) {
                    Menu { Button("Nhắc nhở") {} } label: { HeaderCircle("ellipsis") }.accessibilityLabel("More")
                }
                MooneeHero(mood: .happy, compact: true)
            }
            MooneeHeader(Text(verbatim: "Tài khoản & Cài đặt"))
        }
    }

    private var character: some View {
        Group {
            title("Static (Reduce Motion)")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
                ForEach(MooneeMood.allCases) { m in
                    VStack { MooneeCharacter(mood: m, animated: false).frame(height: 76); Text(m.rawValue).font(.caption2) }
                }
            }.card(padding: 10)
            title("Animated")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
                ForEach(MooneeMood.allCases) { m in
                    VStack { MooneeCharacter(mood: m).frame(height: 96); Text(m.rawValue).font(.caption2) }
                }
            }.card(padding: 10)
            title("Avatar 24 / 28 / 40")
            HStack(spacing: 16) { MooneeAvatar(size: 24); MooneeAvatar(size: 28); MooneeAvatar(size: 40) }.card()
        }
    }

    private var money: some View {
        VStack(alignment: .leading, spacing: 10) {
            AmountText(6_450_000, currency: "VND").font(.largeTitle.bold()).foregroundStyle(Color.ink)
            row("full", AmountText(1_250_000, currency: "VND"))
            row("short", AmountText(1_250_000, currency: "VND", short: true))
            row("short", AmountText(850_000, currency: "VND", short: true))
            row("income +", AmountText(15_000_000, currency: "VND", plus: true).foregroundStyle(Color.income))
            row("expense −", AmountText(-65_000, currency: "VND").foregroundStyle(Color.expense))
            row("USD", AmountText(19_842, currency: "USD"))
            row("hidden", AmountText(245_600_000, currency: "VND").environment(\.balanceHidden, true))
            Text("VoiceOver: " + AmountFormat.spoken(1_250_000, "VND")).font(.caption).foregroundStyle(Color.inkSecondary)
        }
        .card()
    }

    @State private var tab = 1
    private var tabBar: some View {
        let items: [MooneeTabBar<Int>.Item] = [.init(tab: 0, title: "Tổng quan", symbol: "house"), .init(tab: 1, title: "Ngân sách", symbol: "wallet.bifold"),
                                               .init(tab: 2, title: "Quan tâm", symbol: "chart.bar"), .init(tab: 3, title: "Tài khoản", symbol: "person")]
        return VStack(spacing: 40) {
            Color.clear.frame(height: 10)
            MooneeTabBar(items: items, selection: $tab) {}
            MooneeTabBar(items: items, selection: .constant(3)) {}
            Text("Press and hold (+) to see the pressed state.").font(.caption).foregroundStyle(Color.inkSecondary)
        }
        .padding(.horizontal, -16)
    }

    private var jars: some View {
        Group {
            title("Rows in one card: normal / ≥80% / over / negative")
            VStack(spacing: 0) {
                JarCard(name: "Thiết yếu", symbol: "fork.knife", color: JarPalette.color(0), balance: 2_250_000, spent: 3_250_000, budget: 5_500_000, currency: "VND", subtitle: "55%")
                Divider().padding(.leading, 56)
                JarCard(name: "Tiết kiệm", symbol: "banknote", color: JarPalette.color(2), balance: 600_000, spent: 2_400_000, budget: 3_000_000, currency: "VND", subtitle: "10%")
                Divider().padding(.leading, 56)
                JarCard(name: "Hưởng thụ", symbol: "gamecontroller", color: JarPalette.color(4), balance: -250_000, spent: 2_250_000, budget: 2_000_000, currency: "VND", subtitle: "10%")
                Divider().padding(.leading, 56)
                JarCard(name: "Phát triển bản thân", symbol: "book", color: JarPalette.color(3), balance: -150_000, spent: 300_000, budget: 500_000, currency: "VND", subtitle: "10%")
            }
            .card(padding: 0)
            title("Tiles, 4 across")
            HStack(spacing: 8) {
                JarCard(name: "Đầu tư", symbol: "chart.line.uptrend.xyaxis", color: JarPalette.color(1), balance: 1_000_000, spent: 0, budget: 1_000_000, currency: "VND", layout: .tile)
                JarCard(name: "Thiết yếu", symbol: "fork.knife", color: JarPalette.color(0), balance: 3_250_000, spent: 3_575_000, budget: 5_500_000, currency: "VND", layout: .tile)
                JarCard(name: "Tiết kiệm", symbol: "banknote", color: JarPalette.color(2), balance: 2_400_000, spent: 2_400_000, budget: 3_000_000, currency: "VND", layout: .tile)
                JarCard(name: "Hưởng thụ", symbol: "gamecontroller", color: JarPalette.color(4), balance: -250_000, spent: 2_250_000, budget: 2_000_000, currency: "VND", layout: .tile)
            }
        }
    }

    private var bills: some View {
        let day: (Int) -> Date = { Calendar.current.date(byAdding: .day, value: $0, to: .now)! }
        return VStack(alignment: .leading, spacing: 8) {
            title("upcoming / today / overdue / paid")
            BillCard(name: "Internet", symbol: "wifi", amount: 199_000, currency: "VND", due: day(3)) {}
            BillCard(name: "Tiền điện", symbol: "bolt", amount: 650_000, currency: "VND", due: day(0), estimate: true) {}
            BillCard(name: "Thẻ tín dụng", symbol: "creditcard", amount: 2_500_000, currency: "VND", due: day(-2)) {}
            BillCard(name: "Tiền nhà", symbol: "house", amount: 5_000_000, currency: "VND", due: day(-5), paid: true)
        }
    }

    private static let lunch = ChatTransactionCard.Item(id: UUID(), title: "Ăn trưa", symbol: "fork.knife", color: JarPalette.color(0), category: "Ăn uống", jar: "Thiết yếu", when: "Hôm nay", amount: 65_000, currency: "VND")
    private static let book = ChatTransactionCard.Item(id: UUID(), title: "Mua sách", symbol: "book", color: JarPalette.color(3), category: "Sách", jar: "Phát triển bản thân", when: "Hôm nay", amount: 120_000, currency: "VND")
    private static let salary = ChatTransactionCard.Item(id: UUID(), title: "Lương tháng 11", symbol: "banknote", color: .brandPrimary, category: "Lương", jar: nil, amount: 15_000_000, currency: "VND", income: true)

    private var chat: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChatBubble(.moonee, "**Chào bạn!** 👋\nHôm nay mình có thể giúp gì cho bạn?")
            HStack(spacing: 8) {
                QuickReplyChip(title: "Nói chi tiêu", symbol: "mic") {}
                QuickReplyChip(title: "Chụp hóa đơn", symbol: "camera") {}
            }
            ChatBubble(.user, "Ăn trưa 65k, mua sách 120k hôm nay", sent: true)
            ChatBubble(.moonee, "Mình đã ghi nhận 2 giao dịch cho bạn:")
            title("Grouped · saved")
            ChatTransactionCard(items: [Self.lunch, Self.book])
            title("Single income · saved")
            ChatTransactionCard(items: [Self.salary])
            title("Editing")
            ChatTransactionCard(items: [Self.lunch, Self.book], state: .editing)
            title("Undone")
            ChatTransactionCard(items: [Self.lunch], state: .undone)
            ChatBubble(.moonee, "Tháng này bạn đã chi **6.450.000 ₫**, đạt 76% ngân sách tháng. Lọ Hưởng thụ còn 200k, bạn cân nhắc chút nha 💪")
            ChatBubble(.moonee, "Bạn muốn xem gì tiếp?", showsAvatar: false)
            HStack(spacing: 8) {
                QuickReplyChip(title: "Xem báo cáo tháng", symbol: "chart.bar", style: .tile) {}
                QuickReplyChip(title: "Còn bao nhiêu để hưởng thụ?", symbol: "takeoutbag.and.cup.and.straw", style: .tile) {}
                QuickReplyChip(title: "Gợi ý tiết kiệm cuối tháng", symbol: "target", style: .tile) {}
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @State private var draft = ""
    @State private var typed = "Cà phê 35k"
    private var input: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Empty")
            ChatInputBar(text: $draft)
            title("Typing")
            ChatInputBar(text: $typed)
            title("Recording")
            ChatInputBar(text: $draft, isRecording: true)
        }
    }

    private var charts: some View {
        Group {
            title("Progress ring: 45% / 76% / 85% / 112%")
            HStack { ForEach([0.45, 0.76, 0.85, 1.12], id: \.self) { ProgressRing(progress: $0).frame(width: 76) } }.card()
            title("Donut")
            HStack(spacing: 16) {
                DonutChart(slices: [.init(label: "Thiết yếu", value: 3_250_000, color: JarPalette.color(0)),
                                    .init(label: "Đầu tư", value: 1_000_000, color: JarPalette.color(1)),
                                    .init(label: "Tiết kiệm", value: 2_400_000, color: JarPalette.color(2)),
                                    .init(label: "Phát triển", value: 700_000, color: JarPalette.color(3)),
                                    .init(label: "Hưởng thụ", value: 450_000, color: JarPalette.color(4))]) {
                    VStack(spacing: 0) {
                        AmountText(7_800_000, currency: "VND", short: true).font(.headline)
                        Text("đã chi").font(.caption).foregroundStyle(Color.inkSecondary)
                    }
                }
                .frame(width: 150)
                Text("Legend is laid out by each screen.").font(.caption).foregroundStyle(Color.inkSecondary)
            }.card()
        }
    }

    // MARK: helpers

    private func title(_ s: String) -> some View {
        Text(s).font(.headline).foregroundStyle(Color.ink).padding(.top, 6)
    }

    private func row(_ label: String, _ v: some View) -> some View {
        HStack { Text(label).foregroundStyle(Color.inkSecondary); Spacer(); v.font(.title3.weight(.semibold)).foregroundStyle(Color.ink) }
    }

    private func swatches(_ items: [(String, Color)]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(items, id: \.0) { name, color in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 12).fill(color).frame(height: 44)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.black.opacity(0.06)))
                    Text(name).font(.caption2).foregroundStyle(Color.ink)
                }
            }
        }
        .card(padding: 10)
    }
}

#Preview { NavigationStack { ComponentGallery() } }
#endif
