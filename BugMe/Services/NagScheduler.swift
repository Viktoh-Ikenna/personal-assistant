import Foundation
import SwiftData
import UserNotifications

/// Schedules the escalating "nag" notifications and the daily check-in reminders.
/// iOS allows 64 pending local notifications per app, so nags are budgeted and
/// re-planned every time the app opens or a task changes.
@MainActor
final class NagScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NagScheduler()

    static let nagCategory = "BUGME_NAG"
    static let checkInCategory = "BUGME_CHECKIN"
    static let timerCategory = "BUGME_TIMER"
    static let extendAction = "EXTEND"
    static let doneAction = "DONE"
    static let snoozeAction = "SNOOZE"

    private let center = UNUserNotificationCenter.current()
    private let maxTotalNags = 60   // leaves room for the 2 check-ins
    private let maxNagsPerTask = 12

    private static let escalation = [
        "🐞 Time to do this",
        "🐞 Hey, reminder",
        "👀 Still waiting…",
        "🐞🐞 Bugging you again",
        "😤 Seriously now",
        "🐜🐜🐜 The bugs are multiplying",
        "📣 Do it and I'll stop!",
    ]

    func configure() {
        center.delegate = self
        let done = UNNotificationAction(identifier: Self.doneAction, title: "Done ✅", options: [])
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze 15 min", options: [])
        let extend = UNNotificationAction(identifier: Self.extendAction, title: "+10 min", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.nagCategory, actions: [done, snooze], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.checkInCategory, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.timerCategory, actions: [done, extend], intentIdentifiers: [], options: []),
        ])
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    // MARK: - Nags

    func rescheduleNags() async {
        let context = Store.container.mainContext
        let open = (try? context.fetch(FetchDescriptor<BugTask>(predicate: #Predicate { !$0.isDone }))) ?? []
        let openIDs = Set(open.map { $0.uid.uuidString })
        let runningIDs = Set(open.filter(\.isRunning).map { $0.uid.uuidString })

        // Clear all pending nags/timer alerts, and delivered ones that no longer apply.
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.hasPrefix("nag-") || $0.hasPrefix("timer-") })
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter { id in
            (id.hasPrefix("nag-") && !openIDs.contains(where: { id.hasPrefix("nag-\($0)") }))
                || (id.hasPrefix("timer-") && !runningIDs.contains(where: { id.hasPrefix("timer-\($0)") }))
        })

        let now = Date()

        // Timer alerts for the bug you're working on: 5 min left, time's up, then every 5 min over.
        var timerRequests: [UNNotificationRequest] = []
        for task in open where task.isRunning {
            guard let remaining = task.remaining(at: now) else { continue }
            let id = task.uid.uuidString
            func alert(_ suffix: String, after delay: TimeInterval, title: String, body: String) {
                guard delay > 0 else { return }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                content.categoryIdentifier = Self.timerCategory
                content.threadIdentifier = id
                content.userInfo = ["taskID": id]
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
                timerRequests.append(UNNotificationRequest(identifier: "timer-\(id)-\(suffix)", content: content, trigger: trigger))
            }
            if remaining > 6 * 60 { alert("warn", after: remaining - 300, title: "⏳ 5 minutes left", body: task.title) }
            alert("up", after: remaining, title: "⏰ Time's up!", body: "\(task.title). Mark it done or add more time.")
            var over = 0
            for m in stride(from: 5, through: 240, by: 5) where remaining + TimeInterval(m * 60) > 0 {
                alert("over-\(m)", after: remaining + TimeInterval(m * 60), title: "😤 \(m) min over time", body: task.title)
                over += 1
                if over == 6 { break }
            }
        }
        for request in timerRequests { try? await center.add(request) }

        var plan: [(date: Date, task: BugTask, index: Int)] = []
        for task in open where !task.isRunning {
            let interval = TimeInterval(max(1, task.nagIntervalMinutes) * 60)
            let start = task.nagStart
            // If already overdue, continue the rhythm from the next slot after now.
            let first = start > now ? 0 : Int(now.timeIntervalSince(start) / interval) + 1
            for i in 0..<maxNagsPerTask {
                let n = first + i
                plan.append((start.addingTimeInterval(Double(n) * interval), task, n))
            }
        }
        plan.sort { $0.date < $1.date }

        for item in plan.prefix(max(0, maxTotalNags - timerRequests.count)) {
            let content = UNMutableNotificationContent()
            content.title = Self.escalation[min(item.index, Self.escalation.count - 1)]
            content.body = item.task.title
            content.sound = .default
            content.categoryIdentifier = Self.nagCategory
            content.threadIdentifier = item.task.uid.uuidString
            content.userInfo = ["taskID": item.task.uid.uuidString]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, item.date.timeIntervalSince(now)), repeats: false)
            let request = UNNotificationRequest(identifier: "nag-\(item.task.uid.uuidString)-\(item.index)", content: content, trigger: trigger)
            try? await center.add(request)
        }

        try? await center.setBadgeCount(open.filter(\.isOverdue).count)
    }

    func sendTestNag() async {
        let content = UNMutableNotificationContent()
        content.title = "🐞 BugMe test"
        content.body = "This is what a nag looks like. Lock your phone to see it."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content, trigger: trigger))
    }

    // MARK: - Check-ins

    func scheduleCheckIns() {
        let defaults = UserDefaults.standard
        center.removePendingNotificationRequests(withIdentifiers: ["checkin-morning", "checkin-evening"])
        if defaults.bool(forKey: Prefs.morningEnabled) {
            addCheckIn(id: "checkin-morning", minutes: defaults.integer(forKey: Prefs.morningMinutes),
                       title: "☀️ Morning check-in", body: "What will you get done today? I'll bug you about it.")
        }
        if defaults.bool(forKey: Prefs.eveningEnabled) {
            addCheckIn(id: "checkin-evening", minutes: defaults.integer(forKey: Prefs.eveningMinutes),
                       title: "🌙 Evening check-in", body: "How did today go? Take 30 seconds to reflect.")
        }
    }

    private func addCheckIn(id: String, minutes: Int, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.checkInCategory
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: minutes / 60, minute: minutes % 60), repeats: true)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    // MARK: - Delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let taskID = response.notification.request.content.userInfo["taskID"] as? String
        await handle(action: action, category: category, taskID: taskID)
    }

    private func handle(action: String, category: String, taskID: String?) async {
        if category == Self.checkInCategory {
            AppState.shared.selectedTab = .checkIn
            return
        }
        guard let taskID, let uid = UUID(uuidString: taskID) else { return }
        let context = Store.container.mainContext
        let task = try? context.fetch(FetchDescriptor<BugTask>(predicate: #Predicate { $0.uid == uid })).first
        switch action {
        case Self.doneAction: task?.complete(in: context)
        case Self.snoozeAction: task?.snooze(minutes: 15)
        case Self.extendAction: task?.extend(minutes: 10)
        default: AppState.shared.selectedTab = .tasks
        }
        try? context.save()
        await rescheduleNags()
    }
}
