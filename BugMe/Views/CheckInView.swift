import SwiftData
import SwiftUI

struct CheckInView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \CheckIn.date, order: .reverse) private var checkIns: [CheckIn]
    @Query(filter: #Predicate<BugTask> { !$0.isDone }) private var openTasks: [BugTask]
    @Query(filter: #Predicate<BugTask> { $0.isDone }) private var doneTasks: [BugTask]

    @State private var kind = CheckInKind.current
    @State private var mood = 3
    @State private var note = ""
    @State private var makeTasks = true
    @State private var pushOpenToTomorrow = false
    @State private var savedMessage: String?
    @AppStorage(Prefs.morningMinutes) private var morningMinutes = 8 * 60

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Label("\(streak)-day streak", systemImage: "flame.fill").foregroundStyle(.orange)
                        Spacer()
                        Picker("", selection: $kind) {
                            ForEach(CheckInKind.allCases, id: \.self) { Text($0 == .morning ? "Morning" : "Evening").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    if doneToday(kind) {
                        Label("You already did this one today. Add another if you like.", systemImage: "checkmark.seal.fill")
                            .font(.footnote).foregroundStyle(.green)
                    }
                }

                Section("How are you feeling?") {
                    HStack {
                        ForEach(1...5, id: \.self) { value in
                            Button { mood = value } label: {
                                Text(Mood.face(value))
                                    .font(.system(size: 34))
                                    .opacity(mood == value ? 1 : 0.35)
                                    .scaleEffect(mood == value ? 1.15 : 1)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .animation(.spring(duration: 0.25), value: mood)
                }

                Section(kind.prompt) {
                    TextEditor(text: $note).frame(minHeight: 110)
                    if kind == .morning {
                        Toggle("Bug me about each line (every hour)", isOn: $makeTasks)
                    }
                }

                if kind == .evening {
                    Section("Today") {
                        LabeledContent("Finished", value: "\(doneTasks.filter { Calendar.current.isDateInToday($0.completedAt ?? .distantPast) }.count)")
                        LabeledContent("Still open", value: "\(openTasks.count)")
                        if !openTasks.isEmpty {
                            Toggle("Move open bugs to tomorrow morning", isOn: $pushOpenToTomorrow)
                        }
                    }
                }

                Section {
                    Button(action: save) {
                        Label("Save check-in", systemImage: kind.symbol).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .listRowBackground(Color.clear)
                    if let savedMessage {
                        Text(savedMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if !checkIns.isEmpty {
                    Section("History") {
                        ForEach(checkIns.prefix(14)) { c in
                            HStack(alignment: .top) {
                                Text(Mood.face(c.mood)).font(.title2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(c.kind == .morning ? "Morning" : "Evening") · \(c.date.formatted(.dateTime.weekday().month().day()))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if !c.note.isEmpty { Text(c.note).font(.subheadline).lineLimit(3) }
                                }
                            }
                        }
                        .onDelete { idx in idx.map { checkIns[$0] }.forEach(context.delete); try? context.save() }
                    }
                }
            }
            .bugMeBackground()
            .navigationTitle(kind.title)
            .onAppear { kind = CheckInKind.current }
        }
    }

    private var streak: Int {
        let cal = Calendar.current
        let days = Set(checkIns.map { cal.startOfDay(for: $0.date) })
        var day = cal.startOfDay(for: .now)
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var count = 0
        while days.contains(day) {
            count += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }

    private func doneToday(_ kind: CheckInKind) -> Bool {
        checkIns.contains { $0.kind == kind && Calendar.current.isDateInToday($0.date) }
    }

    private func save() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        context.insert(CheckIn(kind: kind, mood: mood, note: text))
        var extra = ""

        if kind == .morning && makeTasks {
            let lines = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -•*0123456789.)")) }
                .filter { !$0.isEmpty }
            for line in lines {
                let parsed = CommandParser.parseTask(line, defaultInterval: 60)
                    ?? ParsedTask(title: line, dueDate: .now, intervalMinutes: 60)
                // Lines without a time start in an hour, so you get a head start.
                let due = parsed.dueDate.timeIntervalSinceNow < 60 ? Date.now.addingTimeInterval(3600) : parsed.dueDate
                context.insert(BugTask(title: parsed.title, dueDate: due, nagIntervalMinutes: parsed.intervalMinutes, recurrence: parsed.recurrence))
            }
            if !lines.isEmpty { extra = " Added \(lines.count) bug\(lines.count == 1 ? "" : "s")." }
        }

        if kind == .evening && pushOpenToTomorrow {
            let cal = Calendar.current
            let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: .now))!
            let start = tomorrow.addingTimeInterval(TimeInterval(morningMinutes * 60 + 30 * 60))
            openTasks.forEach { $0.dueDate = start; $0.snoozedUntil = nil }
            extra = " Moved \(openTasks.count) to tomorrow."
        }

        try? context.save()
        Task { await NagScheduler.shared.rescheduleNags() }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        savedMessage = "Saved \(Mood.face(mood)).\(extra)"
        note = ""
        pushOpenToTomorrow = false
    }
}
