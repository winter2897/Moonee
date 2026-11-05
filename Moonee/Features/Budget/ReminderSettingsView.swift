import SwiftUI
import UserNotifications

/// Reminder level (spec §3.4) + quiet hours. S7 links it from Account; Budget's menu opens it too.
struct ReminderSettingsView: View {
    @AppStorage(Prefs.reminderLevel) private var level = ReminderLevel.medium.rawValue
    @AppStorage(Prefs.quietStart) private var quietStart = 22 * 60
    @AppStorage(Prefs.quietEnd) private var quietEnd = 7 * 60
    @State private var status = UNAuthorizationStatus.notDetermined
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            if status != .authorized {
                Section {
                    Button(status == .denied ? loc("Open Settings to allow notifications") : loc("Turn on notifications"), systemImage: "bell.badge") {
                        if status == .denied {
                            openURL(URL(string: UIApplication.openSettingsURLString)!)
                        } else {
                            Task {
                                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                                await load()
                            }
                        }
                    }
                } footer: {
                    Text(status == .provisional ? loc("Reminders arrive quietly in Notification Center for now.") : loc("Moonee reminds you with local notifications. Nothing leaves your phone."))
                }
            }

            Section {
                Picker(selection: $level) {
                    ForEach(ReminderLevel.allCases) { l in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.title)
                            Text(l.summary).font(.caption).foregroundStyle(Color.inkSecondary)
                        }
                        .tag(l.rawValue)
                    }
                } label: { EmptyView() }
                .pickerStyle(.inline)
            } header: {
                Text(loc("How often"))
            } footer: {
                Text(String(localized: "At most \(ReminderLevel(rawValue: level)?.dailyCap ?? 3) a day. Alerts of the same kind are grouped.", table: "Budget"))
            }

            Section {
                DatePicker(loc("From"), selection: minutes($quietStart), displayedComponents: .hourAndMinute)
                DatePicker(loc("Until"), selection: minutes($quietEnd), displayedComponents: .hourAndMinute)
            } header: {
                Text(loc("Quiet hours"))
            } footer: {
                Text(loc("Reminders that fall in quiet hours wait until they end."))
            }
        }
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .foregroundStyle(Color.ink)
        .navigationTitle(loc("Reminders"))
        .task { await load() }
    }

    private func load() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Minutes after midnight ⇄ a time-of-day Date.
    private func minutes(_ value: Binding<Int>) -> Binding<Date> {
        Binding {
            Calendar.current.date(byAdding: .minute, value: value.wrappedValue, to: Calendar.current.startOfDay(for: .now))!
        } set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            value.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
    }
}
