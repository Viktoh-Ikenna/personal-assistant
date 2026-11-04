import Foundation
import SwiftData

/// Executes a parsed voice/Siri command against the local database and returns a spoken reply.
@MainActor
enum CommandRunner {

    static func run(_ text: String, context: ModelContext? = nil) async -> String {
        let context = context ?? Store.container.mainContext
        switch CommandParser.parse(text, defaultInterval: Prefs.interval) {
        case .add(let parsed):
            return await add(parsed, context: context)
        case .complete(let query):
            return await complete(query, context: context)
        case .list:
            return list(context: context)
        case .checkIn:
            AppState.shared.selectedTab = .checkIn
            return "Let's check in."
        case .start(let query):
            return await start(query, context: context)
        case .pause:
            return await pause(context: context)
        case .unknown:
            return "Sorry, I didn't catch a task in that. Try “bug me to call mom at 5pm”."
        }
    }

    static func add(_ text: String, context: ModelContext? = nil) async -> String {
        guard let parsed = CommandParser.parseTask(text, defaultInterval: Prefs.interval) else {
            return "I didn't catch what to bug you about."
        }
        return await add(parsed, context: context ?? Store.container.mainContext)
    }

    private static func add(_ parsed: ParsedTask, context: ModelContext) async -> String {
        let task = BugTask(title: parsed.title, dueDate: parsed.dueDate, nagIntervalMinutes: parsed.intervalMinutes,
                           recurrence: parsed.recurrence, allocatedMinutes: parsed.allocatedMinutes)
        context.insert(task)
        try? context.save()
        await NagScheduler.shared.rescheduleNags()
        let repeats = parsed.recurrence == .none ? "" : " \(task.recurrenceSummary.lowercasedFirst), starting"
        let budget = parsed.allocatedMinutes > 0 ? " You've got \(Fmt.minutes(parsed.allocatedMinutes)) for it." : ""
        return "Got it. I'll bug you to \(parsed.title.lowercasedFirst)\(repeats) \(Fmt.when(parsed.dueDate)), \(Fmt.interval(parsed.intervalMinutes)) until it's done.\(budget)"
    }

    static func complete(_ query: String, context: ModelContext? = nil) async -> String {
        let open = openTasks(context ?? Store.container.mainContext)
        guard let task = bestMatch(for: query, in: open) else {
            return "I couldn't find an open bug matching “\(query)”."
        }
        let next = task.complete(in: context ?? Store.container.mainContext)
        try? (context ?? Store.container.mainContext).save()
        await NagScheduler.shared.rescheduleNags()
        if let next { return "Nice! “\(task.title)” is done. Next one \(Fmt.when(next))." }
        let left = open.count - 1
        return "Nice! “\(task.title)” is done. " + (left == 0 ? "Your list is clear 🎉" : "\(left) left.")
    }

    /// Starts the timer on the best-matching open bug, or creates one ("start writing the report for 30 minutes").
    static func start(_ query: String, context: ModelContext? = nil) async -> String {
        let context = context ?? Store.container.mainContext
        let parsed = CommandParser.parseTask(query, defaultInterval: Prefs.interval)
        let title = parsed?.title ?? query
        let task: BugTask
        if let match = bestMatch(for: title, in: openTasks(context)) {
            task = match
            if let minutes = parsed?.allocatedMinutes, minutes > 0 { task.allocatedMinutes = minutes }
        } else {
            task = BugTask(title: title, nagIntervalMinutes: Prefs.interval, allocatedMinutes: parsed?.allocatedMinutes ?? 0)
            context.insert(task)
        }
        TimerControl.start(task, context: context)
        try? context.save()
        await NagScheduler.shared.rescheduleNags()
        if let left = task.remaining(), left > 0 {
            return "Timer's running on “\(task.title)”. You've got \(Fmt.duration(left)). I'll tell you when time's up."
        }
        return "Timer's running on “\(task.title)”. Say “stop” when you take a break."
    }

    static func pause(context: ModelContext? = nil) async -> String {
        let context = context ?? Store.container.mainContext
        let running = openTasks(context).filter(\.isRunning)
        guard let task = running.first else { return "No timer is running." }
        running.forEach { $0.pauseTimer() }
        try? context.save()
        await NagScheduler.shared.rescheduleNags()
        return "Paused “\(task.title)” at \(Fmt.duration(task.elapsed()))."
    }

    static func list(context: ModelContext? = nil) -> String {
        let open = openTasks(context ?? Store.container.mainContext)
        guard !open.isEmpty else { return "Nothing on your list. Enjoy it." }
        let items = open.prefix(5).map(\.title).joined(separator: ", ")
        let more = open.count > 5 ? ", and \(open.count - 5) more" : ""
        return "You have \(open.count) \(open.count == 1 ? "thing" : "things"): \(items)\(more)."
    }

    private static func openTasks(_ context: ModelContext) -> [BugTask] {
        let d = FetchDescriptor<BugTask>(predicate: #Predicate { !$0.isDone }, sortBy: [SortDescriptor(\.dueDate)])
        return (try? context.fetch(d)) ?? []
    }

    /// Simple fuzzy match: substring first, then most shared words.
    static func bestMatch(for query: String, in tasks: [BugTask]) -> BugTask? {
        let q = query.lowercased()
        if let exact = tasks.first(where: { $0.title.lowercased().contains(q) || q.contains($0.title.lowercased()) }) {
            return exact
        }
        let stop: Set<String> = ["the", "a", "an", "to", "my", "of", "and", "for", "with", "it"]
        let qWords = Set(q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)).subtracting(stop)
        let scored = tasks.map { task -> (BugTask, Int) in
            let words = Set(task.title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            return (task, words.intersection(qWords).count)
        }
        return scored.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

/// Only one bug's timer runs at a time.
@MainActor
enum TimerControl {
    static func start(_ task: BugTask, context: ModelContext) {
        let running = (try? context.fetch(FetchDescriptor<BugTask>(predicate: #Predicate { $0.timerStartedAt != nil }))) ?? []
        for other in running where other.uid != task.uid { other.pauseTimer() }
        task.startTimer()
    }

    static func toggle(_ task: BugTask, context: ModelContext) {
        if task.isRunning { task.pauseTimer() } else { start(task, context: context) }
    }
}
