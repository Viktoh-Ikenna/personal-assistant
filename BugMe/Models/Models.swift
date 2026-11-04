import Foundation
import SwiftData

@Model
final class BugTask {
    var uid: UUID
    var title: String
    var dueDate: Date
    var nagIntervalMinutes: Int
    var isDone: Bool
    var createdAt: Date
    var completedAt: Date?
    var snoozedUntil: Date?
    var recurrenceRaw: String = "none"
    /// Day of month a monthly bug sticks to (so the 31st doesn't drift to the 28th forever).
    var anchorDay: Int = 0
    /// Time budget for doing the bug (0 = none).
    var allocatedMinutes: Int = 0
    /// Time already spent, not counting the currently running stretch.
    var trackedSeconds: Double = 0
    /// Non-nil while the timer is running.
    var timerStartedAt: Date?

    init(title: String, dueDate: Date = .now, nagIntervalMinutes: Int = 15, recurrence: Recurrence = .none, allocatedMinutes: Int = 0) {
        self.uid = UUID()
        self.title = title
        self.dueDate = dueDate
        self.nagIntervalMinutes = nagIntervalMinutes
        self.isDone = false
        self.createdAt = .now
        self.recurrenceRaw = recurrence.rawValue
        self.anchorDay = Calendar.current.component(.day, from: dueDate)
        self.allocatedMinutes = allocatedMinutes
    }

    // MARK: Time tracking

    var isRunning: Bool { timerStartedAt != nil }
    var hasTimeData: Bool { allocatedMinutes > 0 || trackedSeconds > 0 || isRunning }

    func elapsed(at now: Date = .now) -> TimeInterval {
        trackedSeconds + (timerStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// Seconds left of the allocation (negative when over), or nil if no allocation.
    func remaining(at now: Date = .now) -> TimeInterval? {
        allocatedMinutes > 0 ? TimeInterval(allocatedMinutes * 60) - elapsed(at: now) : nil
    }

    func startTimer() {
        guard timerStartedAt == nil else { return }
        timerStartedAt = .now
        snoozedUntil = nil
    }

    /// Adds time, measured from now if you're already over.
    func extend(minutes: Int) {
        let usedMinutes = Int((elapsed() / 60).rounded(.up))
        allocatedMinutes = max(allocatedMinutes, usedMinutes) + minutes
    }

    func pauseTimer() {
        guard let start = timerStartedAt else { return }
        trackedSeconds += max(0, Date.now.timeIntervalSince(start))
        timerStartedAt = nil
    }

    var recurrence: Recurrence {
        get { Recurrence(rawValue: recurrenceRaw) ?? .none }
        set { recurrenceRaw = newValue.rawValue }
    }

    var recurrenceSummary: String { recurrence.summary(for: dueDate, anchorDay: anchorDay) }

    /// Finishes the bug. A repeating bug logs a "done" copy for history and jumps to its next occurrence.
    @discardableResult
    func complete(in context: ModelContext) -> Date? {
        guard recurrence != .none else { markDone(); return nil }
        pauseTimer()
        let record = BugTask(title: title, dueDate: dueDate, nagIntervalMinutes: nagIntervalMinutes, allocatedMinutes: allocatedMinutes)
        record.trackedSeconds = trackedSeconds
        record.markDone()
        trackedSeconds = 0
        context.insert(record)
        var next = dueDate
        repeat { next = recurrence.next(after: next, anchorDay: anchorDay) } while next <= .now
        dueDate = next
        snoozedUntil = nil
        return next
    }

    /// When nagging (re)starts: the due date, pushed back by any active snooze.
    var nagStart: Date { max(dueDate, snoozedUntil ?? .distantPast) }
    var isOverdue: Bool { !isDone && dueDate <= .now }

    func markDone() {
        pauseTimer()
        isDone = true
        completedAt = .now
        snoozedUntil = nil
    }

    func snooze(minutes: Int) {
        snoozedUntil = Date.now.addingTimeInterval(TimeInterval(minutes * 60))
    }
}

enum Recurrence: String, CaseIterable, Equatable {
    case none, daily, weekly, monthly

    var label: String {
        switch self {
        case .none: "Never"
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }

    func next(after date: Date, anchorDay: Int) -> Date {
        let cal = Calendar.current
        switch self {
        case .none: return date
        case .daily: return cal.date(byAdding: .day, value: 1, to: date)!
        case .weekly: return cal.date(byAdding: .weekOfYear, value: 1, to: date)!
        case .monthly:
            let nextMonth = cal.date(byAdding: .month, value: 1, to: date)!
            let day = anchorDay > 0 ? anchorDay : cal.component(.day, from: date)
            return Self.date(day: day, monthOf: nextMonth, timeFrom: date)
        }
    }

    /// The given day in `month`'s month (clamped to its length), at `timeFrom`'s time.
    static func date(day: Int, monthOf month: Date, timeFrom: Date) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month], from: month)
        let time = cal.dateComponents([.hour, .minute], from: timeFrom)
        let length = cal.range(of: .day, in: .month, for: month)?.count ?? 28
        comps.day = min(max(1, day), length)
        comps.hour = time.hour
        comps.minute = time.minute
        return cal.date(from: comps) ?? month
    }

    func summary(for date: Date, anchorDay: Int) -> String {
        switch self {
        case .none: ""
        case .daily: "Daily"
        case .weekly: "Every " + date.formatted(.dateTime.weekday(.wide))
        case .monthly: "Monthly on the " + Fmt.ordinal(anchorDay > 0 ? anchorDay : Calendar.current.component(.day, from: date))
        }
    }
}

enum CheckInKind: String, CaseIterable {
    case morning, evening

    static var current: CheckInKind {
        Calendar.current.component(.hour, from: .now) < 15 ? .morning : .evening
    }

    var title: String { self == .morning ? "Morning check-in" : "Evening check-in" }
    var prompt: String {
        self == .morning
            ? "What are the 1–3 things you must get done today? (one per line)"
            : "How did today go? What got in the way?"
    }
    var symbol: String { self == .morning ? "sunrise.fill" : "moon.stars.fill" }
}

@Model
final class CheckIn {
    var uid: UUID
    var date: Date
    var kindRaw: String
    var mood: Int
    var note: String

    init(kind: CheckInKind, mood: Int, note: String, date: Date = .now) {
        self.uid = UUID()
        self.date = date
        self.kindRaw = kind.rawValue
        self.mood = mood
        self.note = note
    }

    var kind: CheckInKind { CheckInKind(rawValue: kindRaw) ?? .morning }
}

enum Mood {
    static let faces = ["😫", "😕", "😐", "🙂", "🤩"]
    static func face(_ value: Int) -> String { faces[max(1, min(5, value)) - 1] }
}

@MainActor
enum Store {
    static let container: ModelContainer = {
        do {
            return try ModelContainer(for: BugTask.self, CheckIn.self)
        } catch {
            fatalError("Could not open BugMe database: \(error)")
        }
    }()
}

enum Prefs {
    static let morningEnabled = "morningEnabled"
    static let morningMinutes = "morningMinutes"
    static let eveningEnabled = "eveningEnabled"
    static let eveningMinutes = "eveningMinutes"
    static let defaultInterval = "defaultInterval"
    static let speakReplies = "speakReplies"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            morningEnabled: true,
            morningMinutes: 8 * 60,
            eveningEnabled: true,
            eveningMinutes: 21 * 60,
            defaultInterval: 15,
            speakReplies: true,
        ])
    }

    static var interval: Int { max(1, UserDefaults.standard.integer(forKey: defaultInterval)) }
}

enum AppTab: Hashable { case tasks, checkIn, settings }

@MainActor
@Observable
final class AppState {
    static let shared = AppState()
    var selectedTab: AppTab = .tasks
}

enum Fmt {
    /// Human phrase for when a task starts nagging, e.g. "at 5:00 PM", "in 20 minutes".
    static func when(_ date: Date) -> String {
        let diff = date.timeIntervalSinceNow
        if diff < 60 { return "starting now" }
        if diff < 3600 { return date.formatted(.relative(presentation: .named)) }
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "at \(time)" }
        if cal.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        return "on " + date.formatted(.dateTime.weekday(.wide).month().day().hour().minute())
    }

    static func ordinal(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// "12:34" or "1:02:03".
    static func clock(_ seconds: TimeInterval) -> String {
        let t = Int(abs(seconds))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// "45 min", "1 hr 30 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let mins = Int((seconds / 60).rounded())
        if mins < 1 { return "<1 min" }
        if mins < 60 { return "\(mins) min" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }

    static func minutes(_ m: Int) -> String { duration(TimeInterval(m * 60)) }

    static func interval(_ minutes: Int) -> String {
        if minutes % 60 == 0 {
            let h = minutes / 60
            return h == 1 ? "every hour" : "every \(h) hours"
        }
        return minutes == 1 ? "every minute" : "every \(minutes) min"
    }
}
