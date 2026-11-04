import SwiftUI
import UserNotifications

struct SettingsView: View {
    @AppStorage(Prefs.morningEnabled) private var morningEnabled = true
    @AppStorage(Prefs.morningMinutes) private var morningMinutes = 8 * 60
    @AppStorage(Prefs.eveningEnabled) private var eveningEnabled = true
    @AppStorage(Prefs.eveningMinutes) private var eveningMinutes = 21 * 60
    @AppStorage(Prefs.defaultInterval) private var defaultInterval = 15
    @AppStorage(Prefs.speakReplies) private var speakReplies = true

    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var testSent = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Daily check-ins") {
                    Toggle("Morning", isOn: $morningEnabled)
                    if morningEnabled { DatePicker("Time", selection: time($morningMinutes), displayedComponents: .hourAndMinute) }
                    Toggle("Evening", isOn: $eveningEnabled)
                    if eveningEnabled { DatePicker("Time", selection: time($eveningMinutes), displayedComponents: .hourAndMinute) }
                }

                Section {
                    Picker("Default nag", selection: $defaultInterval) {
                        ForEach([5, 10, 15, 30, 60, 120], id: \.self) { Text(Fmt.interval($0)).tag($0) }
                    }
                    Toggle("Speak replies aloud", isOn: $speakReplies)
                    Button(testSent ? "Sent! Lock your phone…" : "Send a test nag in 5 seconds") {
                        Task { await NagScheduler.shared.sendTestNag(); testSent = true }
                    }
                } header: {
                    Text("Nagging")
                } footer: {
                    Text("BugMe plans up to 12 nags per task in advance. Open the app now and then to keep them coming.")
                }

                Section("Notifications") {
                    LabeledContent("Status", value: statusText)
                    if status == .denied {
                        Button("Open iPhone Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    } else if status == .notDetermined {
                        Button("Allow notifications") {
                            Task { await NagScheduler.shared.requestAuthorization(); await refresh() }
                        }
                    }
                }

                Section {
                    Label("Everything stays on this iPhone. No accounts, no servers, no tracking.", systemImage: "lock.iphone")
                        .font(.footnote)
                }
            }
            .bugMeBackground()
            .navigationTitle("Settings")
            .task { await refresh() }
            .onChange(of: [morningEnabled, eveningEnabled]) { _, _ in NagScheduler.shared.scheduleCheckIns() }
            .onChange(of: [morningMinutes, eveningMinutes]) { _, _ in NagScheduler.shared.scheduleCheckIns() }
        }
    }

    private var statusText: String {
        switch status {
        case .authorized, .provisional, .ephemeral: "On ✅"
        case .denied: "Off — BugMe can't nag you!"
        default: "Not asked yet"
        }
    }

    private func refresh() async {
        status = await NagScheduler.shared.authorizationStatus()
    }

    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: .now) ?? .now },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }
}
