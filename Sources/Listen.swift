import AVFoundation
import Foundation
import QuartzCore
import Speech

// Saying a todo instead of typing it. macOS's own recogniser does the work, on this Mac and nothing leaves it:
// no model to download, no service to call, and nothing added to Ledge's size. macOS asks once for the microphone
// and once for speech recognition.
//
// It listens until you stop talking (or you press Esc), hands the words to Island, and meters the microphone on
// the way through so the island can show the bars moving while you speak.

final class Listen {
    static let silenceAfter = 1.6 // quiet that ends a todo, once you've started
    static let waitForFirstWords = 8.0 // how long to wait for you to start at all
    static let longest = 30.0 // a stuck recogniser mustn't listen forever
    static let speaking = 0.22 // a level above this counts as someone talking, not room tone
    static let bars = 4

    var onStart: (() -> Void)? // listening has begun: the island shows itself
    var onText: ((String) -> Void)? // what's been heard so far
    var onLevels: (([Double]) -> Void)? // the microphone, for the bars
    var onDone: ((String?) -> Void)? // the finished words, or nil if nothing was said
    var onTrouble: ((String) -> Void)? // permission refused, or the recogniser is unavailable
    private(set) var running = false

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var heard = ""
    private var tick: Timer?
    private var startedAt = 0.0
    private var lastLoud = 0.0 // when the microphone last heard something above room tone
    private var said = false // the recogniser has given us words
    private var metered = 0.0

    /// Start listening, or stop if it already is.
    func toggle() {
        if running { stop(keep: true) } else { ask() }
    }

    // ---------- permission ----------

    private func ask() {
        guard recognizer != nil else { onTrouble?("Speech recognition isn't available for your language."); return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    self.onTrouble?("Ledge needs permission to recognise speech. Turn it on in System Settings › Privacy & Security › Speech Recognition.")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    DispatchQueue.main.async {
                        guard allowed else {
                            self.onTrouble?("Ledge needs the microphone to hear a todo. Turn it on in System Settings › Privacy & Security › Microphone.")
                            return
                        }
                        self.begin()
                    }
                }
            }
        }
    }

    // ---------- listening ----------

    private func begin() {
        guard !running, let recognizer else { return }
        guard recognizer.isAvailable else { onTrouble?("Speech recognition isn't ready just now. Try again in a moment."); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Keep it on this Mac. Without on-device support the words would go to Apple, so rather than do that
        // quietly, say so and stop.
        guard recognizer.supportsOnDeviceRecognition else {
            onTrouble?("Your Mac can't recognise speech without sending it to Apple, so Ledge won't listen. Type the todo instead (⌘T).")
            return
        }
        req.requiresOnDeviceRecognition = true
        req.taskHint = .dictation
        request = req
        heard = ""

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.inputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            self?.meter(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            request = nil
            onTrouble?("Ledge couldn't start listening: \(error.localizedDescription)")
            return
        }
        running = true
        startedAt = CACurrentMediaTime()
        lastLoud = startedAt
        said = false
        onStart?() // the island opens its box now, not when the first words land
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self, self.running else { return }
            if let result {
                let words = result.bestTranscription.formattedString
                if !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if words != self.heard { self.lastLoud = CACurrentMediaTime() } // still talking
                    self.heard = words
                    self.said = true
                    self.onText?(words)
                }
                if result.isFinal { self.stop(keep: true) }
            }
            // An error with nothing heard is a real failure; after words, it's just the end of the audio.
            if error != nil { self.stop(keep: !self.heard.isEmpty) }
        }
        // One clock for all three endings: you stopped talking, you never started, or it has gone on too long.
        tick = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.check() }
    }

    /// The only thing that ends a todo, so a slow recogniser can't cut you off before you've spoken.
    private func check() {
        guard running else { return }
        let now = CACurrentMediaTime()
        if now - startedAt > Listen.longest { return stop(keep: true) }
        // Nothing said yet: wait, rather than stop a moment after the microphone opens.
        guard said else {
            if now - startedAt > Listen.waitForFirstWords { stop(keep: false) }
            return
        }
        if now - lastLoud > Listen.silenceAfter { stop(keep: true) }
    }

    /// Stop. keep: use what was heard (false throws it away, for Esc).
    func stop(keep: Bool) {
        tick?.invalidate(); tick = nil
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        let said = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        heard = ""
        onLevels?(Array(repeating: 0, count: Listen.bars))
        onDone?(keep && !said.isEmpty ? said : nil)
    }

    // ---------- the bars ----------

    /// How loud the microphone is, as four levels that move together but not alike, so it reads as a voice.
    private func meter(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum = 0.0
        for i in 0..<n { let v = Double(data[i]); sum += v * v }
        let db = 20 * log10(max((sum / Double(n)).squareRoot(), 1e-7))
        let level = min(1, max(0, (db + 52) / 44))
        let now = CACurrentMediaTime()
        if level > Listen.speaking { lastLoud = now } // still talking, even between words
        guard now - metered > 1 / 24.0 else { return } // the page only needs so many
        metered = now
        let levels = (0..<Listen.bars).map { i in
            min(1, max(0.08, level * (0.72 + 0.28 * sin(Double(i) * 1.9 + now * 9))))
        }
        DispatchQueue.main.async { [weak self] in self?.onLevels?(levels) }
    }
}
