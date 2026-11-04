import SwiftData
import SwiftUI

@main
struct BugMeApp: App {
    init() {
        Prefs.registerDefaults()
        NagScheduler.shared.configure()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-seedDemo") { Self.seedDemo() }
        #endif
    }

    #if DEBUG
    /// Sample data for screenshots: `xcrun simctl launch <device> <bundle id> -seedDemo`
    private static func seedDemo() {
        let ctx = Store.container.mainContext
        try? ctx.delete(model: BugTask.self)
        for text in ["Call mom at 5pm every 10 minutes", "Pay rent on the 1st of every month", "Gym every monday at 6pm",
                     "Submit invoice next friday at 10am", "Take vitamins every day at 9am"] {
            if let p = CommandParser.parseTask(text, defaultInterval: 15) {
                ctx.insert(BugTask(title: p.title, dueDate: p.dueDate, nagIntervalMinutes: p.intervalMinutes, recurrence: p.recurrence))
            }
        }
        ctx.insert(BugTask(title: "Reply to Ada's email", dueDate: .now.addingTimeInterval(-1800), nagIntervalMinutes: 15))
        let report = BugTask(title: "Write the quarterly report", dueDate: .now.addingTimeInterval(-600), allocatedMinutes: 45)
        report.trackedSeconds = 12 * 60 + 34
        report.timerStartedAt = .now
        ctx.insert(report)
        let slides = BugTask(title: "Prepare pitch slides", dueDate: .now.addingTimeInterval(3 * 3600), allocatedMinutes: 60)
        slides.trackedSeconds = 20 * 60
        ctx.insert(slides)
        let done = BugTask(title: "Book dentist appointment")
        done.markDone()
        ctx.insert(done)
        try? ctx.save()
    }
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    await NagScheduler.shared.requestAuthorization()
                    NagScheduler.shared.scheduleCheckIns()
                    await NagScheduler.shared.rescheduleNags()
                }
        }
        .modelContainer(Store.container)
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: Binding(get: { AppState.shared.selectedTab }, set: { AppState.shared.selectedTab = $0 })) {
            TaskListView()
                .tabItem { Label("Bugs", systemImage: "ant.fill") }
                .tag(AppTab.tasks)
            CheckInView()
                .tabItem { Label("Check-in", systemImage: "sun.and.horizon.fill") }
                .tag(AppTab.checkIn)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .tint(Theme.orange)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await NagScheduler.shared.rescheduleNags() }
            }
        }
    }
}
