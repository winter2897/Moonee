import SwiftUI

// MARK: - Bubbles

struct ChatBubble<Content: View>: View {
    enum Sender { case moonee, user }

    let sender: Sender
    /// Hide the avatar on consecutive Moonee messages; the space is kept so bubbles line up.
    var showsAvatar = true
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if sender == .moonee {
                MooneeAvatar(size: 40).opacity(showsAvatar ? 1 : 0)
                bubble
                Spacer(minLength: 24)
            } else {
                Spacer(minLength: 56)
                bubble
            }
        }
    }

    private var bubble: some View {
        content
            .font(.callout)
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(sender == .moonee ? Color.surface : Color.brandMintSoft, in: .rect(cornerRadius: 22))
            .shadow(color: .brandDeep.opacity(sender == .moonee ? 0.06 : 0), radius: 8, y: 3)
    }
}

extension ChatBubble where Content == Text {
    /// Plain message; `**bold**` markdown is rendered (Moonee bolds the amounts).
    init(_ sender: Sender, _ message: String, showsAvatar: Bool = true) {
        self.sender = sender
        self.showsAvatar = showsAvatar
        let md = try? AttributedString(markdown: message, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        self.content = Text(md ?? AttributedString(message))
    }
}

// MARK: - Transaction card

/// Saved transactions shown in the chat right after Moonee records them (spec §3.1).
struct ChatTransactionCard: View {
    struct Item: Identifiable {
        let id: UUID
        let title: String
        let symbol: String
        let color: Color
        /// "Category · Jar", e.g. "Sách · Phát triển bản thân" (spec §E). `when` is prepended if set.
        let category: String
        let jar: String?
        var when: String? = nil
        let amount: Int
        let currency: String
        var income = false
    }

    enum State { case saved, editing, undone }

    let items: [Item]
    var state: State = .saved
    var onUndo: () -> Void = {}
    var onEdit: (Item.ID) -> Void = { _ in }
    var onDoneEditing: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                row(item)
                if item.id != items.last?.id { Divider().padding(.leading, 60) }
            }
            footer.padding(.top, 8)
        }
        .padding(12)
        .background(Color.surface, in: .rect(cornerRadius: 22))
        .overlay {
            if state == .editing { RoundedRectangle(cornerRadius: 22).strokeBorder(Color.brandPrimary, lineWidth: 2) }
        }
        .shadow(color: .brandDeep.opacity(0.07), radius: 10, y: 4)
    }

    private func row(_ item: Item) -> some View {
        let line = [item.when, item.category, item.jar].compactMap { $0 }.joined(separator: " · ")
        let content = HStack(spacing: 12) {
            IconBadge(symbol: item.symbol, color: item.color, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.headline)
                Text(line).font(.footnote).foregroundStyle(Color.inkSecondary)
            }
            Spacer(minLength: 8)
            AmountText(item.income ? item.amount : -item.amount, currency: item.currency, plus: item.income)
                .font(.headline)
                .foregroundStyle(item.income ? Color.income : Color.expense)
            if state == .editing {
                Image(systemName: "pencil.circle.fill").font(.title2).foregroundStyle(Color.brandPrimary)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(Color.ink)
        .strikethrough(state == .undone)
        .opacity(state == .undone ? 0.45 : 1)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .contentShape(.rect)

        return Group {
            if state == .editing {
                Button { onEdit(item.id) } label: { content }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Edit", tableName: "Components"))
            } else {
                content.accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        switch state {
        case .saved:
            banner(symbol: "checkmark.circle.fill", tint: .brandPrimary, text: Text("Saved to your ledger", tableName: "Components")) {
                Button(action: onUndo) {
                    Label { Text("Undo", tableName: "Components") } icon: { Image(systemName: "arrow.uturn.backward") }
                }
                .buttonStyle(OutlinePillStyle())
            }
        case .editing:
            banner(symbol: "pencil", tint: .brandDeep, text: Text("Tap a line to edit", tableName: "Components")) {
                Button(action: onDoneEditing) { Text("Done", tableName: "Components") }
                    .buttonStyle(OutlinePillStyle(filled: true))
            }
        case .undone:
            banner(symbol: "arrow.uturn.backward.circle.fill", tint: .inkSecondary, text: Text("Undone, nothing was saved", tableName: "Components"), background: .track.opacity(0.5)) {
                EmptyView()
            }
        }
    }

    private func banner(symbol: String, tint: Color, text: Text, background: Color = .brandMintSoft.opacity(0.7), @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint).accessibilityHidden(true)
            text.font(.footnote).foregroundStyle(Color.ink)
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(minHeight: 52)
        .background(background, in: .rect(cornerRadius: 16))
    }
}

/// Small capsule button: outlined green ("Undo") or filled ("Done"). 44 pt tall touch area.
struct OutlinePillStyle: ButtonStyle {
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(filled ? Color.white : Color.brandDeep)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background {
                if filled { Capsule().fill(LinearGradient.brand) } else { Capsule().fill(Color.surface) }
            }
            .overlay { if !filled { Capsule().strokeBorder(Color.brandPrimary, lineWidth: 1.5) } }
            .frame(minHeight: 44)
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Quick replies

/// Suggested reply. `.chip` = one-line capsule (Nói chi tiêu), `.tile` = icon over two lines (Xem báo cáo tháng).
struct QuickReplyChip: View {
    enum Style { case chip, tile }

    let title: String
    var symbol: String? = nil
    var style: Style = .chip
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                switch style {
                case .chip:
                    HStack(spacing: 8) {
                        if let symbol { Image(systemName: symbol).foregroundStyle(Color.brandPrimary) }
                        Text(title).lineLimit(1)
                    }
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    .background(Color.surface, in: .capsule)
                case .tile:
                    VStack(spacing: 6) {
                        if let symbol { Image(systemName: symbol).font(.title2).foregroundStyle(Color.brandPrimary) }
                        Text(title).multilineTextAlignment(.center).lineLimit(3)
                    }
                    .padding(12).frame(maxWidth: .infinity, minHeight: 88, maxHeight: .infinity)
                    .background(Color.surface, in: .rect(cornerRadius: 20))
                }
            }
            .font(.subheadline)
            .foregroundStyle(Color.ink)
            .shadow(color: .brandDeep.opacity(0.06), radius: 6, y: 2)
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Shrinks a little while pressed (disabled with Reduce Motion: dims instead).
struct PressScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Input bar

struct ChatInputBar: View {
    @Binding var text: String
    var isRecording = false
    var onPhoto: () -> Void = {}
    var onMic: () -> Void = {}
    var onSend: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if !isRecording {
                roundButton("photo", tint: .brandDeep, label: Text("Attach photo", tableName: "Components"), action: onPhoto)
            }
            roundButton(isRecording ? "stop.fill" : "mic.fill", tint: isRecording ? .danger : .brandDeep,
                        label: isRecording ? Text("Stop recording", tableName: "Components") : Text("Voice input", tableName: "Components"),
                        action: onMic)

            Group {
                if isRecording {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform")
                            .foregroundStyle(Color.danger)
                            .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                        Text("Listening…", tableName: "Components").foregroundStyle(Color.ink)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    TextField(String(localized: "Message Moonee…", table: "Components"), text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .foregroundStyle(Color.ink)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .frame(minHeight: 48)
            .background(isRecording ? Color.danger.opacity(0.08) : Color.surface, in: .capsule)
            .overlay { if isRecording { Capsule().strokeBorder(Color.danger.opacity(0.4)) } }

            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(LinearGradient.brand, in: .circle)
                    .shadow(color: .brandPrimary.opacity(0.35), radius: 8, y: 4)
            }
            .buttonStyle(PressScaleStyle())
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.45)
            .accessibilityLabel(Text("Send", tableName: "Components"))
        }
    }

    private func roundButton(_ symbol: String, tint: Color, label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(Color.surface, in: .circle)
                .shadow(color: .brandDeep.opacity(0.06), radius: 6, y: 2)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }
}
