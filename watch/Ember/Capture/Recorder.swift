import AVFoundation
import Foundation
import Observation

/// Records an idea to a WAV file, 16 kHz mono 16-bit, the way the server
/// hears it: for when dictation is not there (an older watch with no
/// network), or when you would rather just talk.
@Observable
@MainActor
final class Recorder {
    enum Problem: LocalizedError {
        case noMicrophone
        case couldNotStart

        var errorDescription: String? {
            switch self {
            case .noMicrophone: return "Ember can't use the microphone. Allow it in Settings, Privacy, Microphone."
            case .couldNotStart: return "The recording could not start."
            }
        }
    }

    static let longest: TimeInterval = 5 * 60

    private(set) var recording = false
    private(set) var elapsed: TimeInterval = 0
    /// How loud it is now, 0 to 1, for the picture.
    private(set) var level: Double = 0

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var fileName: String?

    func start() async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw Problem.noMicrophone
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        try FileManager.default.createDirectory(
            at: NoteStore.recordings, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".wav"
        let made = try AVAudioRecorder(url: NoteStore.recording(name), settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        made.isMeteringEnabled = true
        guard made.record(forDuration: Self.longest) else { throw Problem.couldNotStart }
        recorder = made
        fileName = name
        recording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
    }

    private func tick() {
        guard let recorder else { return }
        if !recorder.isRecording {
            // It reached the longest a recording can be.
            timer?.invalidate()
            recording = false
            return
        }
        elapsed = recorder.currentTime
        recorder.updateMeters()
        let power = Double(recorder.averagePower(forChannel: 0))
        level = max(0, min(1, (power + 50) / 50))
    }

    /// Stop, and give the file's name and how long it is: nil when it was
    /// too short to hold anything.
    func finish() -> (name: String, seconds: Double)? {
        let seconds = recorder?.currentTime ?? elapsed
        stop()
        guard let fileName else { return nil }
        self.fileName = nil
        if seconds < 0.5 && elapsed < 0.5 {
            try? FileManager.default.removeItem(at: NoteStore.recording(fileName))
            return nil
        }
        return (fileName, max(seconds, elapsed))
    }

    func discard() {
        stop()
        if let fileName {
            try? FileManager.default.removeItem(at: NoteStore.recording(fileName))
        }
        fileName = nil
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
