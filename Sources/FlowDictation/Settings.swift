import Foundation

enum TranscriptionMode: String, Codable {
    case local
    case openai
    case groq
    case auto
}

enum LLMProvider: String, Codable {
    case none
    case openai
    case groq
    case auto
}

enum HotkeyKind: String, Codable {
    case fn
    case shortcut
}

struct HotkeySettings: Codable {
    var kind: HotkeyKind = .fn
    var keyCode: Int = 49 // Space
    var modifiers: [String] = ["command", "shift"]
}

struct LocalWhisperSettings: Codable {
    var whisperBinary: String = "bundled"
    var modelPath: String = "~/Library/Application Support/FlowDictation/Models/ggml-small.en.bin"
    var extraArgs: [String] = []
}

struct APITranscriptionSettings: Codable {
    var mode: TranscriptionMode = .local
    var openAIModel: String = "whisper-1"
    var groqModel: String = "whisper-large-v3-turbo"
}

struct LLMSettings: Codable {
    var enabled: Bool = true
    var provider: LLMProvider = .auto
    var openAIModel: String = "gpt-4o-mini"
    var groqModel: String = "llama-3.1-8b-instant"
}

struct CleanupSettings: Codable {
    var verbatimMode: Bool = false
    var removeFillers: Bool = true
    var resolveRetractions: Bool = true
    var improveHinglish: Bool = true
    var formatLists: Bool = true
    var deterministicFormatting: Bool = true
    var paragraphBreaksFromPauses: Bool = true
    var skipLLMForSimpleClips: Bool = true
    var maximumEditDistanceRatio: Double = 0.72
    var minimumOutputWordRatio: Double = 0.45
    var maximumOutputWordRatio: Double = 1.55
}

struct Settings: Codable {
    var enabled: Bool = true
    var hotkey: HotkeySettings = .init()
    var transcription: APITranscriptionSettings = .init()
    var localWhisper: LocalWhisperSettings = .init()
    var llm: LLMSettings = .init()
    var cleanup: CleanupSettings = .init()
    var pasteRestoreDelayMilliseconds: Int = 350

    enum CodingKeys: String, CodingKey {
        case enabled, hotkey, transcription, localWhisper, llm, cleanup, pasteRestoreDelayMilliseconds
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        hotkey = try values.decodeIfPresent(HotkeySettings.self, forKey: .hotkey) ?? .init()
        transcription = try values.decodeIfPresent(APITranscriptionSettings.self, forKey: .transcription) ?? .init()
        localWhisper = try values.decodeIfPresent(LocalWhisperSettings.self, forKey: .localWhisper) ?? .init()
        llm = try values.decodeIfPresent(LLMSettings.self, forKey: .llm) ?? .init()
        cleanup = try values.decodeIfPresent(CleanupSettings.self, forKey: .cleanup) ?? .init()
        pasteRestoreDelayMilliseconds = try values.decodeIfPresent(Int.self, forKey: .pasteRestoreDelayMilliseconds) ?? 350
    }
}

final class SettingsStore {
    let configURL: URL

    init() {
        let environment = ProcessInfo.processInfo.environment
        if let configuredPath = environment["FLOW_DICTATION_CONFIG"], !configuredPath.isEmpty {
            configURL = URL(fileURLWithPath: Self.expand(configuredPath))
        } else {
            configURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".flow-dictation", isDirectory: true)
                .appendingPathComponent("config.json")
        }
    }

    func load() throws -> Settings {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            try save(Settings())
        }
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(Settings.self, from: data)
    }

    func save(_ settings: Settings) throws {
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: configURL, options: .atomic)
    }

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

enum DotEnv {
    static func load(from directories: [URL]) -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        for directory in directories {
            let url = directory.appendingPathComponent(".env")
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in content.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                let unexported = trimmed.hasPrefix("export ") ? String(trimmed.dropFirst(7)) : trimmed
                guard let separator = unexported.firstIndex(of: "=") else { continue }
                let key = String(unexported[..<separator]).trimmingCharacters(in: .whitespaces)
                var value = String(unexported[unexported.index(after: separator)...])
                    .trimmingCharacters(in: .whitespaces)
                if value.count >= 2,
                   let first = value.first,
                   (first == "\"" || first == "'"),
                   value.last == first {
                    value.removeFirst()
                    value.removeLast()
                }
                if !key.isEmpty, result[key] == nil || result[key]?.isEmpty == true {
                    result[key] = value
                }
            }
        }
        return result
    }
}
