import AVFoundation
import Foundation
import Speech

/// On-device speech-to-text (falls back to Apple's recognizer only if the device can't do it locally).
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var errorMessage: String?
    @Published var isOnDevice = false

    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() async {
        errorMessage = nil
        guard await requestPermissions() else {
            errorMessage = "BugMe needs Microphone and Speech Recognition access. Turn them on in Settings."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available right now."
            return
        }
        stop()
        transcript = ""

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = false
            isOnDevice = recognizer.supportsOnDeviceRecognition
            if isOnDevice { request.requiresOnDeviceRecognition = true }

            let engine = AVAudioEngine()
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tapBlock(for: request))
            engine.prepare()
            try engine.start()

            self.engine = engine
            self.request = request
            self.task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(for: self))
            isRecording = true
        } catch {
            errorMessage = error.localizedDescription
            stop()
        }
    }

    func stop() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        engine = nil
        request = nil
        task = nil
        isRecording = false
    }

    private func receive(text: String?, isFinal: Bool, failed: Bool) {
        if let text, isRecording || isFinal { transcript = text }
        if isFinal || failed { stop() }
    }

    // Built outside the main actor: these run on audio / recognition threads.
    nonisolated private static func tapBlock(for request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func resultHandler(for owner: SpeechRecognizer) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in owner?.receive(text: text, isFinal: isFinal, failed: failed) }
        }
    }

    private func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// Reads replies aloud.
@MainActor
final class Speaker {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()

    func say(_ text: String) {
        guard UserDefaults.standard.bool(forKey: Prefs.speakReplies) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text.replacingOccurrences(of: "“", with: "").replacingOccurrences(of: "”", with: ""))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synth.speak(utterance)
    }
}
