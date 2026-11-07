import SwiftUI

// MARK: - Bubbles

struct ChatBubble<Content: View>: View {
    enum Sender { case moonee, user }

    let sender: Sender
    /// Hide the avatar on consecutive Moonee messages; the space is kept so bubbles line up.
    var showsAvatar = true
    /// User messages: a ✓✓ at the bubble's bottom-right once saved (mockup).
    var sent = false
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if sender == .moonee {
                MooneeAvatar(size: 34).opacity(showsAvatar ? 1 : 0)
                bubble
                Spacer(minLength: 24)
            } else {
                Spacer(minLength: 56)
                bubble
            }
        }
    }

    private var bubble: some View {
        HStack(alignment: .bottom, spacing: 6) {
            content
            if sent && sender == .user {
                // ponytail: SF Symbols has no double tick; two checkmarks overlap.
                HStack(spacing: -5) { Image(systemName: "checkmark"); Image(systemName: "checkmark") }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.brandDeep)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Sent", tableName: "Components"))
            }
        }
            .font(.bodyText)
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(sender == .moonee ? Color.surface : Color.brandMintSoft, in: .rect(cornerRadius: 18))
            .shadow(color: .brandDeep.opacity(sender == .moonee ? 0.06 : 0), radius: 8, y: 3)
    }
}

extension ChatBubble where Content == Text {
    /// Plain message; `**bold**` markdown is rendered (Moonee bolds the amounts).
    init(_ sender: Sender, _ message: String, showsAvatar: Bool = true, sent: Bool = false) {
        self.sender = sender
        self.showsAvatar = showsAvatar
        self.sent = sent
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
        /// "Category · Jar", e.g. "Sách · Phát triển bản thân" (spec §E). `when` is appended if set.
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
    /// The card's Edit button: the chat opens the editor (one line) or the edit mode (several).
    var onStartEditing: () -> Void = {}
    var onEdit: (Item.ID) -> Void = { _ in }
    var onDoneEditing: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                row(item)
                if item.id != items.last?.id { Divider().padding(.leading, 44) }
            }
            footer.padding(.top, 8)
        }
        .padding(10)
        .background(Color.surface, in: .rect(cornerRadius: 18))
        .overlay {
            if state == .editing { RoundedRectangle(cornerRadius: 18).strokeBorder(Color.brandPrimary, lineWidth: 2) }
        }
        .shadow(color: .brandDeep.opacity(0.07), radius: 10, y: 4)
    }

    private func row(_ item: Item) -> some View {
        let line = [item.category, item.jar, item.when].compactMap { $0 }.joined(separator: " · ")
        let content = HStack(spacing: 10) {
            IconBadge(symbol: item.symbol, color: item.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.rowTitle).lineLimit(2)
                Text(line).font(.caption).foregroundStyle(Color.inkSecondary).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
            Spacer(minLength: 8)
            AmountText(item.income ? item.amount : -item.amount, currency: item.currency, plus: item.income)
                .font(.rowTitle)
                .foregroundStyle(item.income ? Color.income : Color.expense)
            if state == .editing {
                Image(systemName: "pencil.circle.fill").font(.title3).foregroundStyle(Color.brandPrimary)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(Color.ink)
        .strikethrough(state == .undone)
        .opacity(state == .undone ? 0.45 : 1)
        .padding(.vertical, 6)
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
            banner(symbol: "checkmark.circle.fill", tint: .brandPrimary, text: Text("Saved", tableName: "Components")) {
                HStack(spacing: 6) {
                    Button(action: onStartEditing) {
                        Label { Text("Edit", tableName: "Components") } icon: { Image(systemName: "pencil") }
                    }
                    Button(action: onUndo) {
                        Label { Text("Undo", tableName: "Components") } icon: { Image(systemName: "arrow.uturn.backward") }
                    }
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
            Image(systemName: symbol).font(.body).foregroundStyle(tint).accessibilityHidden(true)
            text.font(.secondaryText).foregroundStyle(Color.ink)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1).minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(minHeight: 44)
        .background(background, in: .rect(cornerRadius: 14))
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
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            Group {
                switch style {
                case .chip:
                    // 36 pt visual, 44 pt touch target.
                    HStack(spacing: 6) {
                        if let symbol { Image(systemName: symbol).foregroundStyle(Color.brandPrimary) }
                        Text(title).lineLimit(1)
                    }
                    .font(.chip)
                    .padding(.horizontal, 14).frame(minHeight: 36)
                    .background(Color.surface, in: .capsule)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                case .tile:
                    VStack(spacing: 4) {
                        if let symbol { Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(Color.brandPrimary) }
                        Text(title).font(.caption).multilineTextAlignment(.center).lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 56, maxHeight: .infinity)
                    .background(Color.surface, in: .rect(cornerRadius: 16))
                }
            }
            .foregroundStyle(Color.ink)
            .shadow(color: .brandDeep.opacity(0.06), radius: 6, y: 2)
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Shrinks a little while pressed (disabled with Reduce Motion: dims instead).
struct PressScaleStyle: ButtonStyle {
    var scale = 0.95
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Input bar

struct ChatInputBar: View {
    @Binding var text: String
    var isRecording = false
    /// Lets the screen focus the text field (the Moonee tab opens with the keyboard up).
    var focus: FocusState<Bool>.Binding? = nil
    var onPhoto: () -> Void = {}
    var onMic: () -> Void = {}
    var onSend: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        // 40 pt visuals in 44 pt touch targets; 4 pt spacing + 2 pt margins = 8 pt between visuals.
        HStack(alignment: .bottom, spacing: 4) {
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
                    let field = TextField(String(localized: "Message Moonee…", table: "Components"), text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .foregroundStyle(Color.ink)
                    if let focus { field.focused(focus) } else { field }
                }
            }
            .font(.bodyText)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(minHeight: 40)
            .background(isRecording ? Color.danger.opacity(0.08) : Color.surface, in: .capsule)
            .overlay { if isRecording { Capsule().strokeBorder(Color.danger.opacity(0.4)) } }
            .padding(.vertical, 2)

            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(LinearGradient.brand, in: .circle)
                    .shadow(color: .brandPrimary.opacity(0.35), radius: 8, y: 4)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
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
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(Color.surface, in: .circle)
                .shadow(color: .brandDeep.opacity(0.06), radius: 6, y: 2)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }
}
