import SwiftData
import SwiftUI

struct TaskListView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<BugTask> { !$0.isDone }, sort: \BugTask.dueDate) private var openTasks: [BugTask]
    @Query(filter: #Predicate<BugTask> { $0.isDone }, sort: [SortDescriptor(\BugTask.completedAt, order: .reverse)]) private var doneTasks: [BugTask]

    @State private var editing: BugTask?
    @State private var showingAdd = false
    @State private var showingVoice = false

    private var cal: Calendar { .current }
    private var waiting: [BugTask] { openTasks.filter { !$0.isRunning } }
    private var overdue: [BugTask] { waiting.filter { $0.dueDate <= .now } }
    private var today: [BugTask] { waiting.filter { $0.dueDate > .now && cal.isDateInToday($0.dueDate) } }
    private var upcoming: [BugTask] { waiting.filter { $0.dueDate > .now && !cal.isDateInToday($0.dueDate) } }
    private var doneToday: [BugTask] { doneTasks.filter { cal.isDateInToday($0.completedAt ?? .distantPast) } }

    var body: some View {
        NavigationStack {
            List {
                header
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                if let active = openTasks.first(where: \.isRunning) {
                    ActiveTimerCard(task: active,
                                    pause: { active.pauseTimer(); save() },
                                    extend: { active.extend(minutes: 10); save() },
                                    done: { complete(active) })
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }

                if openTasks.isEmpty {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                taskSection("Overdue", icon: "flame.fill", tint: Theme.red, tasks: overdue)
                taskSection("Today", icon: "sun.max.fill", tint: Theme.orange, tasks: today)
                taskSection("Upcoming", icon: "calendar", tint: .indigo, tasks: upcoming)

                if !doneToday.isEmpty {
                    Section {
                        ForEach(doneToday) { task in
                            row(for: task)
                                .swipeActions { Button(role: .destructive) { delete(task) } label: { Label("Delete", systemImage: "trash") } }
                        }
                    } header: {
                        sectionHeader("Done today", icon: "checkmark.seal.fill", tint: .green, count: doneToday.count)
                    }
                }
            }
            .listStyle(.plain)
            .listSectionSpacing(8)
            .bugMeBackground()
            .contentMargins(.bottom, 90, for: .scrollContent)
            .overlay(alignment: .bottom) { floatingButtons }
            .navigationTitle("BugMe")
            .toolbar {
                if !doneTasks.isEmpty {
                    Menu {
                        Button("Clear finished bugs", systemImage: "trash", role: .destructive) {
                            doneTasks.forEach(context.delete)
                            save()
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showingAdd) { TaskEditor(task: nil) }
            .sheet(item: $editing) { TaskEditor(task: $0) }
            .sheet(isPresented: $showingVoice) {
                VoiceSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        let total = doneToday.count + overdue.count + today.count + openTasks.filter(\.isRunning).count
        let progress = total == 0 ? 0 : Double(doneToday.count) / Double(total)
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month().day()).uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(greeting).font(.title2.weight(.bold))
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
                if trackedToday >= 60 {
                    HStack(spacing: 4) { Image(systemName: "stopwatch"); Text("\(Fmt.duration(trackedToday)) tracked") }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.orange)
                }
            }
            Spacer(minLength: 0)
            ZStack {
                ProgressRing(progress: progress)
                VStack(spacing: 0) {
                    Text("\(doneToday.count)").font(.title3.weight(.bold))
                    Text("of \(total)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
        }
        .card(padding: 18)
    }

    private var trackedToday: TimeInterval {
        doneToday.reduce(0) { $0 + $1.trackedSeconds } + openTasks.reduce(0) { $0 + $1.elapsed() }
    }

    private var greeting: String {
        switch cal.component(.hour, from: .now) {
        case 5..<12: "Good morning ☀️"
        case 12..<17: "Good afternoon 🌤️"
        case 17..<22: "Good evening 🌆"
        default: "Still up? 🌙"
        }
    }

    private var summary: String {
        if openTasks.isEmpty { return "Nothing bugging you. Enjoy it." }
        if !overdue.isEmpty { return "\(overdue.count) overdue. I'm on your case 🐞" }
        if !today.isEmpty { return "\(today.count) coming up today." }
        return "All clear for today."
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("🐞").font(.system(size: 56))
            Text("Nothing to bug you about").font(.headline)
            Text("Tap the mic and say something like\n“pay rent on the 1st of every month”")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private func taskSection(_ title: String, icon: String, tint: Color, tasks: [BugTask]) -> some View {
        if !tasks.isEmpty {
            Section {
                ForEach(tasks) { task in
                    row(for: task)
                        .swipeActions(edge: .leading) {
                            Button { complete(task) } label: { Label("Done", systemImage: "checkmark") }.tint(.green)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { delete(task) } label: { Label("Delete", systemImage: "trash") }
                            Button { task.snooze(minutes: 60); save() } label: { Label("1 hr", systemImage: "moon.zzz") }.tint(.indigo)
                            Button { task.snooze(minutes: 15); save() } label: { Label("15 min", systemImage: "zzz") }.tint(.purple)
                        }
                }
            } header: {
                sectionHeader(title, icon: icon, tint: tint, count: tasks.count)
            }
        }
    }

    private func sectionHeader(_ title: String, icon: String, tint: Color, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Text("\(count)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Spacer()
        }
        .textCase(nil)
        .padding(.top, 6)
    }

    private func row(for task: BugTask) -> some View {
        TaskCard(task: task,
                 toggle: { task.isDone ? reopen(task) : complete(task) },
                 toggleTimer: { withAnimation(.snappy) { TimerControl.toggle(task, context: context) }; save() })
            .contentShape(Rectangle())
            .onTapGesture { if !task.isDone { editing = task } }
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private var floatingButtons: some View {
        HStack(spacing: 12) {
            Button { showingAdd = true } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.orange)
                    .frame(width: 50, height: 50)
                    .background(Theme.orange.opacity(0.14), in: Circle())
            }
            .accessibilityLabel("Add a bug")

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showingVoice = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill").font(.system(size: 20, weight: .bold))
                    Text("Talk").font(.headline)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .frame(height: 50)
                .background(Theme.gradient, in: Capsule())
            }
            .accessibilityLabel("Talk to BugMe")
        }
        .padding(7)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
        .padding(.bottom, 14)
    }

    // MARK: - Actions

    private func complete(_ task: BugTask) {
        withAnimation(.snappy) { task.complete(in: context) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        save()
    }

    private func reopen(_ task: BugTask) {
        withAnimation(.snappy) {
            task.isDone = false
            task.completedAt = nil
            if task.dueDate < .now { task.dueDate = .now }
        }
        save()
    }

    private func delete(_ task: BugTask) {
        withAnimation { context.delete(task) }
        save()
    }

    private func save() {
        try? context.save()
        Task { await NagScheduler.shared.rescheduleNags() }
    }
}

struct TaskCard: View {
    let task: BugTask
    let toggle: () -> Void
    var toggleTimer: (() -> Void)? = nil

    private var accent: Color {
        if task.isDone || task.isRunning { return .green }
        if task.isOverdue { return Theme.red }
        if Calendar.current.isDateInToday(task.dueDate) { return Theme.orange }
        return .indigo
    }

    var body: some View {
        if task.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in card(now: context.date) }
        } else {
            card(now: .now)
        }
    }

    private func card(now: Date) -> some View {
        HStack(spacing: 14) {
            Button(action: toggle) {
                ZStack {
                    Circle()
                        .strokeBorder(task.isDone ? Color.green : accent.opacity(0.6), lineWidth: 2.5)
                        .background(Circle().fill(task.isDone ? Color.green : .clear))
                    if task.isDone {
                        Image(systemName: "checkmark").font(.caption.weight(.heavy)).foregroundStyle(.white)
                    }
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "Mark not done" : "Mark done")

            VStack(alignment: .leading, spacing: 7) {
                Text(task.title)
                    .font(.body.weight(.semibold))
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? .secondary : .primary)
                    .lineLimit(2)

                if task.isDone {
                    if task.trackedSeconds >= 30 {
                        Chip(text: "Took \(Fmt.duration(task.trackedSeconds))", systemImage: "stopwatch", tint: .green)
                    }
                } else {
                    FlowLayout(spacing: 6) { chips(now: now) }
                    if let left = task.remaining(at: now), task.trackedSeconds > 0 || task.isRunning {
                        ProgressView(value: min(1, max(0, 1 - left / TimeInterval(task.allocatedMinutes * 60))))
                            .tint(left < 0 ? Theme.red : .green)
                    }
                }
            }
            Spacer(minLength: 0)

            if !task.isDone, let toggleTimer {
                Button(action: toggleTimer) {
                    Image(systemName: task.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(task.isRunning ? .white : Theme.orange)
                        .frame(width: 40, height: 40)
                        .background {
                            if task.isRunning { Circle().fill(Color.green) } else { Circle().fill(Theme.orange.opacity(0.14)) }
                        }
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(task.isRunning ? "Pause timer" : "Start timer")
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18)
                .fill(accent)
                .frame(width: 5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        .opacity(task.isDone ? 0.7 : 1)
    }

    @ViewBuilder
    private func chips(now: Date) -> some View {
        if task.isRunning {
            if let left = task.remaining(at: now) {
                Chip(text: left >= 0 ? "\(Fmt.clock(left)) left" : "+\(Fmt.clock(left)) over",
                     systemImage: "timer", tint: left >= 0 ? .green : Theme.red)
            } else {
                Chip(text: Fmt.clock(task.elapsed(at: now)), systemImage: "timer", tint: .green)
            }
        } else if let snooze = task.snoozedUntil, snooze > .now {
            Chip(text: "Snoozed till \(snooze.formatted(date: .omitted, time: .shortened))", systemImage: "zzz", tint: .purple)
        } else if task.isOverdue {
            Chip(text: "Bugging you", systemImage: "bell.and.waves.left.and.right.fill", tint: Theme.red)
        } else {
            Chip(text: Fmt.when(task.dueDate).capitalizedFirst, systemImage: "clock", tint: accent)
        }
        if !task.isRunning {
            if task.allocatedMinutes > 0 {
                let used = task.trackedSeconds >= 60 ? "\(Int(task.trackedSeconds / 60)) of " : ""
                Chip(text: "\(used)\(Fmt.minutes(task.allocatedMinutes))", systemImage: "hourglass", tint: .orange)
            } else if task.trackedSeconds >= 60 {
                Chip(text: "\(Fmt.duration(task.trackedSeconds)) tracked", systemImage: "stopwatch", tint: .orange)
            }
        }
        if task.recurrence != .none {
            Chip(text: task.recurrenceSummary, systemImage: "repeat", tint: .teal)
        }
        if !task.isRunning {
            Chip(text: Fmt.interval(task.nagIntervalMinutes).capitalizedFirst, systemImage: "bell", tint: .secondary)
        }
    }
}

/// Big live timer shown at the top while you're working on a bug.
struct ActiveTimerCard: View {
    let task: BugTask
    let pause: () -> Void
    let extend: () -> Void
    let done: () -> Void

    private static let green = [Color(red: 0.16, green: 0.72, blue: 0.45), Color(red: 0.05, green: 0.55, blue: 0.5)]
    private static let red = [Theme.red, Color(red: 0.7, green: 0.1, blue: 0.2)]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let elapsed = task.elapsed(at: now)
        let left = task.remaining(at: now)
        let over = (left ?? 1) < 0
        let budget = TimeInterval(max(1, task.allocatedMinutes) * 60)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: over ? "exclamationmark.triangle.fill" : "timer")
                    Text(over ? "Over time" : "Working on")
                }
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                Spacer()
                if task.allocatedMinutes > 0 {
                    Text("\(Fmt.minutes(task.allocatedMinutes)) allotted").font(.caption.weight(.semibold))
                }
            }
            .opacity(0.9)

            Text(task.title).font(.title3.weight(.bold)).lineLimit(2)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(left.map { ($0 < 0 ? "+" : "") + Fmt.clock($0) } ?? Fmt.clock(elapsed))
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(left == nil ? "elapsed" : (over ? "over" : "left"))
                    .font(.headline)
                    .opacity(0.85)
            }

            if task.allocatedMinutes > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(.white).frame(width: geo.size.width * min(1, elapsed / budget))
                    }
                }
                .frame(height: 8)
            }

            HStack(spacing: 10) {
                pill("Pause", icon: "pause.fill", filled: false, action: pause)
                if task.allocatedMinutes > 0 {
                    pill("+10 min", icon: "plus", filled: false, action: extend)
                }
                Spacer()
                pill("Done", icon: "checkmark", filled: true, action: done)
            }
            .padding(.top, 2)
        }
        .foregroundStyle(.white)
        .padding(18)
        .background(
            LinearGradient(colors: over ? Self.red : Self.green, startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .shadow(color: (over ? Theme.red : Color.green).opacity(0.35), radius: 14, y: 6)
    }

    private func pill(_ title: String, icon: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { Image(systemName: icon); Text(title) }
                .font(.subheadline.weight(.bold))
                .fixedSize()
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(filled ? Color(red: 0.05, green: 0.5, blue: 0.4) : .white)
                .background(filled ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.2)), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct TaskEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let task: BugTask?

    @State private var smartText = ""
    @State private var title = ""
    @State private var due = Date.now
    @State private var interval = Prefs.interval
    @State private var recurrence = Recurrence.none
    @State private var allocated = 0
    @State private var resetTime = false
    @FocusState private var smartFocused: Bool

    private let intervals = [1, 5, 10, 15, 30, 45, 60, 120, 240]
    private let budgets = [0, 5, 10, 15, 20, 25, 30, 45, 60, 90, 120, 180, 240]

    var body: some View {
        NavigationStack {
            Form {
                if task == nil {
                    Section {
                        TextField("e.g. pay rent on the 1st of every month", text: $smartText, axis: .vertical)
                            .focused($smartFocused)
                            .submitLabel(.done)
                            .onSubmit(applySmartText)
                            .onChange(of: smartText) { _, _ in applySmartText() }
                    } header: {
                        Label("Just type it", systemImage: "sparkles")
                    } footer: {
                        Text("BugMe fills in the details below as you type.")
                    }
                }

                Section("What") {
                    TextField("What should I bug you about?", text: $title)
                        .font(.body.weight(.semibold))
                }

                Section {
                    DatePicker("Start bugging", selection: $due)
                    Picker("Nag me", selection: $interval) {
                        ForEach(Array(Set(intervals + [interval])).sorted(), id: \.self) { Text(Fmt.interval($0).capitalizedFirst).tag($0) }
                    }
                } header: {
                    Text("When")
                }

                Section {
                    Picker("Time needed", selection: $allocated) {
                        ForEach(Array(Set(budgets + [allocated])).sorted(), id: \.self) {
                            Text($0 == 0 ? "No limit" : Fmt.minutes($0)).tag($0)
                        }
                    }
                    if let task, task.trackedSeconds > 0 || task.isRunning, !resetTime {
                        LabeledContent("Time spent", value: Fmt.duration(task.elapsed()))
                        Button("Reset time spent", role: .destructive) { resetTime = true }
                    }
                } header: {
                    Text("Time")
                } footer: {
                    Text("Tap ▶︎ on the bug to start the timer. BugMe warns you 5 minutes before time's up and keeps bugging you if you go over.")
                }

                Section {
                    Picker("Repeats", selection: $recurrence) {
                        ForEach(Recurrence.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Repeats")
                } footer: {
                    if recurrence != .none {
                        Text("\(recurrence.summary(for: due, anchorDay: Calendar.current.component(.day, from: due))) at \(due.formatted(date: .omitted, time: .shortened)). When you mark it done, BugMe sets up the next one.")
                    }
                }
            }
            .bugMeBackground()
            .navigationTitle(task == nil ? "New bug" : "Edit bug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.bold)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let task {
                    title = task.title
                    due = task.dueDate
                    interval = task.nagIntervalMinutes
                    recurrence = task.recurrence
                    allocated = task.allocatedMinutes
                } else {
                    smartFocused = true
                }
            }
        }
    }

    private func applySmartText() {
        guard let parsed = CommandParser.parseTask(smartText, defaultInterval: Prefs.interval) else { return }
        title = parsed.title
        due = parsed.dueDate
        interval = parsed.intervalMinutes
        recurrence = parsed.recurrence
        allocated = parsed.allocatedMinutes
    }

    private func save() {
        let clean = title.trimmingCharacters(in: .whitespaces)
        if let task {
            task.title = clean
            task.dueDate = due
            task.nagIntervalMinutes = interval
            task.recurrence = recurrence
            task.anchorDay = Calendar.current.component(.day, from: due)
            task.snoozedUntil = nil
            task.allocatedMinutes = allocated
            if resetTime {
                task.trackedSeconds = 0
                task.timerStartedAt = nil
            }
        } else {
            context.insert(BugTask(title: clean, dueDate: due, nagIntervalMinutes: interval, recurrence: recurrence, allocatedMinutes: allocated))
        }
        try? context.save()
        Task { await NagScheduler.shared.rescheduleNags() }
        dismiss()
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
