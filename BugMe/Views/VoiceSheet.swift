import SwiftUI

/// Opened from the floating mic button. Starts listening immediately.
struct VoiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speech = SpeechRecognizer()
    @State private var reply = "I'm listening. What should I bug you about?"
    @State private var lastHeard = ""
    @State private var typed = ""
    @State private var pulse = false

    private let examples = [
        "Call mom at 5pm every 10 minutes",
        "Write the report for 45 minutes",
        "Start the report",
        "Stop",
        "Pay rent on the 1st of every month",
        "Drink water every 30 minutes",
        "Gym every monday at 6pm",
        "Take the bins out tomorrow at 7am",
        "What's on my list?",
        "I finished calling mom",
    ]

    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .top, spacing: 10) {
                Text("🐞")
                    .font(.title)
                    .frame(width: 44, height: 44)
                    .background(Theme.orange.opacity(0.15), in: Circle())
                Text(reply)
                    .font(.body)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .animation(.default, value: reply)
            }
            .padding(.top, 24)

            Button(action: toggleMic) {
                ZStack {
                    Circle()
                        .fill((speech.isRecording ? Theme.red : Theme.orange).opacity(0.18))
                        .frame(width: 128, height: 128)
                        .scaleEffect(pulse ? 1.15 : 0.95)
                    Circle()
                        .fill(speech.isRecording ? AnyShapeStyle(Theme.red) : AnyShapeStyle(Theme.gradient))
                        .frame(width: 92, height: 92)
                        .shadow(color: Theme.red.opacity(0.4), radius: 12, y: 5)
                    Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(speech.isRecording ? "Stop listening" : "Start listening")
            .animation(speech.isRecording ? .easeInOut(duration: 0.8).repeatForever() : .default, value: pulse)

            Text(speech.isRecording ? (speech.transcript.isEmpty ? "Listening…" : speech.transcript) : (lastHeard.isEmpty ? "Tap the mic to talk" : lastHeard))
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(speech.isRecording ? .primary : .secondary)
                .frame(minHeight: 44)

            if let error = speech.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(examples, id: \.self) { ex in
                        Button { execute(ex) } label: {
                            Text(ex)
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Theme.card, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.horizontal, -20)

            HStack {
                TextField("…or type it", text: $typed)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Theme.card, in: Capsule())
                    .submitLabel(.send)
                    .onSubmit(sendTyped)
                Button(action: sendTyped) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)).foregroundStyle(Theme.orange)
                }
                .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .background(BugMeBackground())
        // Auto-stop after ~1.5s of silence once something has been heard.
        .task(id: speech.transcript) {
            guard speech.isRecording, !speech.transcript.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(1500))
            if !Task.isCancelled && speech.isRecording { finishListening() }
        }
        .task { await speech.start() }
        .onChange(of: speech.isRecording) { _, recording in pulse = recording }
        .onChange(of: AppState.shared.selectedTab) { _, _ in dismiss() }
        .onDisappear { speech.stop() }
    }

    private func toggleMic() {
        if speech.isRecording {
            finishListening()
        } else {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task { await speech.start() }
        }
    }

    private func finishListening() {
        let text = speech.transcript
        speech.stop()
        execute(text)
    }

    private func sendTyped() {
        execute(typed)
        typed = ""
    }

    private func execute(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lastHeard = "“\(text)”"
        Task {
            reply = await CommandRunner.run(text)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            Speaker.shared.say(reply)
        }
    }
}
