import AppIntents

struct AddBugIntent: AppIntent {
    static var title: LocalizedStringResource = "Bug Me About Something"
    static var description = IntentDescription("Tell BugMe what to nag you about, like “call mom at 5pm every 10 minutes”.")

    @Parameter(title: "What", requestValueDialog: IntentDialog("What should I bug you about?"))
    var request: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await CommandRunner.add(request)
        return .result(dialog: "\(reply)")
    }
}

struct ListBugsIntent: AppIntent {
    static var title: LocalizedStringResource = "What's On My List"
    static var description = IntentDescription("Hear what BugMe is currently bugging you about.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(CommandRunner.list())")
    }
}

struct MarkDoneIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark a Bug Done"
    static var description = IntentDescription("Tell BugMe you finished something so it stops nagging.")

    @Parameter(title: "Task", requestValueDialog: IntentDialog("What did you finish?"))
    var task: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await CommandRunner.complete(task)
        return .result(dialog: "\(reply)")
    }
}

struct StartTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Start a Bug Timer"
    static var description = IntentDescription("Start tracking time on a bug.")

    @Parameter(title: "Task", requestValueDialog: IntentDialog("What are you working on?"))
    var task: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await CommandRunner.start(task)
        return .result(dialog: "\(reply)")
    }
}

struct PauseTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause Bug Timer"
    static var description = IntentDescription("Pause the running timer.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await CommandRunner.pause()
        return .result(dialog: "\(reply)")
    }
}

struct BugMeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddBugIntent(),
                    phrases: ["Bug me with \(.applicationName)", "Add a bug in \(.applicationName)", "\(.applicationName) bug me"],
                    shortTitle: "Bug Me", systemImageName: "ant.fill")
        AppShortcut(intent: ListBugsIntent(),
                    phrases: ["What's on my \(.applicationName) list", "List my \(.applicationName) bugs"],
                    shortTitle: "My Bugs", systemImageName: "list.bullet")
        AppShortcut(intent: MarkDoneIntent(),
                    phrases: ["Mark a bug done in \(.applicationName)", "I finished something in \(.applicationName)"],
                    shortTitle: "Done", systemImageName: "checkmark.circle.fill")
        AppShortcut(intent: StartTimerIntent(),
                    phrases: ["Start a timer in \(.applicationName)", "Start working in \(.applicationName)"],
                    shortTitle: "Start Timer", systemImageName: "play.circle.fill")
        AppShortcut(intent: PauseTimerIntent(),
                    phrases: ["Pause \(.applicationName)", "Stop the \(.applicationName) timer"],
                    shortTitle: "Pause Timer", systemImageName: "pause.circle.fill")
    }
}
