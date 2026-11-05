import SwiftData
import SwiftUI

/// Past conversations: pinned first, then by day; search, star, swipe to delete. Opened from the chat header.
struct ChatHistoryView: View {
    let onOpen: (ChatThread) -> Void
    let onNew: () -> Void
    @Query(sort: \ChatThread.createdAt, order: .reverse) private var threads: [ChatThread]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var toDelete: ChatThread?

    var body: some View {
        let sections = ChatThreads.sections(threads, query: query)
        NavigationStack {
            List {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.threads) { row($0) }
                    } header: {
                        header(section.kind)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(MooneeBackground())
            .overlay {
                if sections.isEmpty {
                    if query.isEmpty {
                        EmptyState(mood: .sleepy, title: String(localized: "No chats yet", table: "Chat"),
                                   message: String(localized: "Your conversations with Moonee show up here, one per day.", table: "Chat")) { EmptyView() }
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .searchable(text: $query, prompt: Text("Search chats", tableName: "Chat"))
            .navigationTitle(Text("Chat history", tableName: "Chat"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("Done", tableName: "Chat") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onNew()
                        dismiss()
                    } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel(Text("New chat", tableName: "Chat"))
                }
            }
            .confirmationDialog(Text("Delete this chat? Transactions it saved stay in your ledger.", tableName: "Chat"),
                                isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                                titleVisibility: .visible) {
                Button(role: .destructive) {
                    if let t = toDelete { context.delete(t) } // messages cascade; their txns are only unlinked
                    try? context.save()
                    toDelete = nil
                } label: { Text("Delete", tableName: "Chat") }
            }
        }
    }

    private func row(_ t: ChatThread) -> some View {
        Button {
            onOpen(t)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title.isEmpty ? String(localized: "New chat", table: "Chat") : t.title)
                        .font(.rowTitle).foregroundStyle(Color.ink).lineLimit(1)
                    if let last = t.sortedMessages.last {
                        Text(last.text.replacingOccurrences(of: "**", with: ""))
                            .font(.secondaryText).foregroundStyle(Color.inkSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if t.isPinned {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(Color.brandYellow)
                        .accessibilityLabel(Text("Pinned", tableName: "Chat"))
                }
                Text(t.createdAt, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(Color.inkSecondary)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .listRowBackground(Color.surface.opacity(0.85))
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { toDelete = t } label: {
                Label { Text("Delete", tableName: "Chat") } icon: { Image(systemName: "trash") }
            }
        }
        .swipeActions(edge: .leading) {
            Button { t.isPinned.toggle() } label: {
                t.isPinned ? Label { Text("Unpin", tableName: "Chat") } icon: { Image(systemName: "star.slash") }
                           : Label { Text("Pin", tableName: "Chat") } icon: { Image(systemName: "star") }
            }
            .tint(.brandYellow)
        }
    }

    @ViewBuilder private func header(_ kind: ChatThreads.Section.Kind) -> some View {
        switch kind {
        case .pinned: Text("Pinned", tableName: "Chat")
        case .day(let day):
            if Calendar.current.isDateInToday(day) { Text("Today", tableName: "Chat") }
            else if Calendar.current.isDateInYesterday(day) { Text("Yesterday", tableName: "Chat") }
            else { Text(day, format: .dateTime.weekday(.wide).day().month()) }
        }
    }
}
