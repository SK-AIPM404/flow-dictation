import Foundation

enum DictationError: LocalizedError {
    case missingConfiguration(String)
    case processFailed(String)
    case remoteService(String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let message), .processFailed(let message), .remoteService(let message): return message
        case .emptyTranscript: return "The transcription service returned no text."
        }
    }
}

final class TranscriptionService {
    private let settings: Settings
    private let environment: [String: String]

    init(settings: Settings, environment: [String: String]) {
        self.settings = settings
        self.environment = environment
    }

    func transcribe(file: URL) async throws -> String {
        let rawTranscript: String
        switch resolvedMode() {
        case .local:
            rawTranscript = try transcribeLocally(file: file)
        case .openai:
            guard let key = environment["OPENAI_API_KEY"], !key.isEmpty else {
                throw DictationError.missingConfiguration("OPENAI_API_KEY is missing from .env.")
            }
            rawTranscript = try await transcribeRemotely(
                file: file,
                endpoint: "https://api.openai.com/v1/audio/transcriptions",
                key: key,
                model: settings.transcription.openAIModel
            )
        case .groq:
            guard let key = environment["GROQ_API_KEY"], !key.isEmpty else {
                throw DictationError.missingConfiguration("GROQ_API_KEY is missing from .env.")
            }
            rawTranscript = try await transcribeRemotely(
                file: file,
                endpoint: "https://api.groq.com/openai/v1/audio/transcriptions",
                key: key,
                model: settings.transcription.groqModel
            )
        case .auto:
            rawTranscript = try transcribeLocally(file: file)
        }
        return TranscriptDeduplicator.collapseRepeatedUtterance(in: rawTranscript)
    }

    private func resolvedMode() -> TranscriptionMode {
        guard settings.transcription.mode == .auto else { return settings.transcription.mode }
        if let key = environment["OPENAI_API_KEY"], !key.isEmpty { return .openai }
        if let key = environment["GROQ_API_KEY"], !key.isEmpty { return .groq }
        return .local
    }

    private func transcribeLocally(file: URL) throws -> String {
        let binary = resolvedWhisperBinary()
        let model = SettingsStore.expand(settings.localWhisper.modelPath)
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw DictationError.missingConfiguration("whisper.cpp binary not found or not executable: \(binary)")
        }
        guard FileManager.default.fileExists(atPath: model) else {
            throw DictationError.missingConfiguration("whisper.cpp model not found: \(model)")
        }

        let process = Process()
        let outputPrefix = file.deletingPathExtension().path + "-transcript"
        let textOutput = URL(fileURLWithPath: outputPrefix).appendingPathExtension("txt")
        let vttOutput = URL(fileURLWithPath: outputPrefix).appendingPathExtension("vtt")
        defer {
            try? FileManager.default.removeItem(at: textOutput)
            try? FileManager.default.removeItem(at: vttOutput)
        }
        process.executableURL = URL(fileURLWithPath: binary)
        var processEnvironment = ProcessInfo.processInfo.environment
        if let bundledBackends = Bundle.main.resourceURL?.appendingPathComponent("ggml-backends", isDirectory: true),
           FileManager.default.fileExists(atPath: bundledBackends.path) {
            processEnvironment["GGML_BACKEND_PATH"] = bundledBackends.path
        }
        process.environment = processEnvironment
        var arguments = ["-m", model, "-f", file.path, "-nt", "-otxt", "-of", outputPrefix]
        if settings.cleanup.paragraphBreaksFromPauses { arguments.append("-ovtt") }
        if !hasThreadOverride(settings.localWhisper.extraArgs) {
            let threads = min(8, max(4, ProcessInfo.processInfo.activeProcessorCount - 2))
            arguments += ["-t", String(threads)]
        }
        process.arguments = arguments + settings.localWhisper.extraArgs
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errors = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw DictationError.processFailed(errors.isEmpty ? "whisper.cpp exited with status \(process.terminationStatus)." : errors)
        }
        let transcriptSource = (try? String(contentsOf: textOutput, encoding: .utf8)) ?? output
        let plainTranscript = transcriptSource
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript: String
        if settings.cleanup.paragraphBreaksFromPauses,
           let vtt = try? String(contentsOf: vttOutput, encoding: .utf8),
           let paragraphs = WhisperVTT.paragraphText(from: vtt, minimumGap: 1.2),
           !paragraphs.isEmpty {
            transcript = paragraphs
        } else {
            transcript = plainTranscript
        }
        guard !transcript.isEmpty else { throw DictationError.emptyTranscript }
        return transcript
    }

    private func hasThreadOverride(_ arguments: [String]) -> Bool {
        arguments.contains { $0 == "-t" || $0 == "--threads" }
    }

    private func resolvedWhisperBinary() -> String {
        let configured = SettingsStore.expand(settings.localWhisper.whisperBinary)
        if configured != "bundled", FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        if let bundled = Bundle.main.url(forResource: "whisper-cli", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        let homebrewFallback = "/opt/homebrew/bin/whisper-cli"
        if FileManager.default.isExecutableFile(atPath: homebrewFallback) {
            return homebrewFallback
        }
        return configured
    }

    private func transcribeRemotely(file: URL, endpoint: String, key: String, model: String) async throws -> String {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let boundary = "FlowDictation-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Multipart.formData(
            fields: ["model": model, "response_format": "json"],
            file: file,
            boundary: boundary
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DictationError.remoteService(String(data: data, encoding: .utf8) ?? "Transcription request failed.")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DictationError.emptyTranscript
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum WhisperVTT {
    private struct Segment {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    static func paragraphText(from content: String, minimumGap: TimeInterval) -> String? {
        let lines = content.components(separatedBy: .newlines)
        var segments: [Segment] = []
        var index = 0

        while index < lines.count {
            let timing = lines[index].trimmingCharacters(in: .whitespaces)
            guard timing.contains(" --> "), let range = timing.range(of: " --> ") else {
                index += 1
                continue
            }
            let startText = String(timing[..<range.lowerBound])
            let endText = String(timing[range.upperBound...]).split(separator: " ").first.map(String.init) ?? ""
            guard let start = timestamp(startText), let end = timestamp(endText) else {
                index += 1
                continue
            }
            index += 1
            var captionLines: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                captionLines.append(lines[index])
                index += 1
            }
            let caption = captionLines
                .joined(separator: " ")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !caption.isEmpty { segments.append(Segment(start: start, end: end, text: caption)) }
        }

        guard !segments.isEmpty else { return nil }
        var paragraphs = ""
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                let gap = max(0, segment.start - segments[index - 1].end)
                paragraphs += gap >= minimumGap ? "\n\n" : " "
            }
            paragraphs += segment.text
        }
        return paragraphs.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func timestamp(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2].replacingOccurrences(of: ",", with: ".")) else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }
}

enum TranscriptDeduplicator {
    static func collapseRepeatedUtterance(in transcript: String) -> String {
        let words = transcript.split(whereSeparator: \.isWhitespace)
        guard words.count >= 4 else { return transcript }
        let normalized = words.map(normalize)

        for unitLength in stride(from: words.count / 2, through: 2, by: -1) {
            guard words.count.isMultiple(of: unitLength) else { continue }
            let firstUnit = Array(normalized.prefix(unitLength))
            let repeats = words.count / unitLength
            let isRepeated = (1..<repeats).allSatisfy { index in
                let start = index * unitLength
                return Array(normalized[start..<(start + unitLength)]) == firstUnit
            }
            if isRepeated {
                return words.prefix(unitLength).joined(separator: " ")
            }
        }
        return transcript
    }

    private static func normalize(_ word: Substring) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}

enum Multipart {
    static func formData(fields: [String: String], file: URL, boundary: String) throws -> Data {
        var data = Data()
        for (name, value) in fields {
            data.appendString("--\(boundary)\r\n")
            data.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            data.appendString("\(value)\r\n")
        }
        data.appendString("--\(boundary)\r\n")
        data.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\n")
        data.appendString("Content-Type: audio/wav\r\n\r\n")
        data.append(try Data(contentsOf: file))
        data.appendString("\r\n--\(boundary)--\r\n")
        return data
    }
}

extension Data {
    mutating func appendString(_ string: String) {
        append(string.data(using: .utf8)!)
    }
}
