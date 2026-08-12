import AVFoundation
import Foundation

enum RecorderError: LocalizedError {
    case alreadyRecording
    case notRecording

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A recording is already in progress."
        case .notRecording: return "There is no recording to stop."
        }
    }
}

final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    func start() throws {
        guard engine == nil else { throw RecorderError.alreadyRecording }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-dictation-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let wavFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: wavFormat) else {
            throw DictationError.processFailed("Could not create a WAV audio converter.")
        }
        let file = try AVAudioFile(
            forWriting: outputURL,
            settings: wavFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        audioFile = file
        self.converter = converter
        outputFormat = wavFormat
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            self?.write(buffer)
        }
        newEngine.prepare()
        try newEngine.start()
        recordingURL = outputURL
        engine = newEngine
    }

    func stop() throws -> URL {
        guard let engine, let recordingURL else { throw RecorderError.notRecording }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
        converter = nil
        outputFormat = nil
        self.engine = nil
        self.recordingURL = nil
        return recordingURL
    }

    private func write(_ inputBuffer: AVAudioPCMBuffer) {
        guard let converter, let outputFormat, let audioFile else { return }
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 64)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, conversionError == nil else {
            NSLog("FlowDictation could not convert audio: %@", conversionError?.localizedDescription ?? "unknown error")
            return
        }
        do {
            try audioFile.write(from: outputBuffer)
        } catch {
            NSLog("FlowDictation could not write audio: %@", error.localizedDescription)
        }
    }
}
