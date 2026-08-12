import Foundation

final class TranscriptRefiner {
    private let settings: Settings
    private let environment: [String: String]

    init(settings: Settings, environment: [String: String]) {
        self.settings = settings
        self.environment = environment
    }

    func refine(_ transcript: String) async throws -> String {
        let cleanup = settings.cleanup
        guard !cleanup.verbatimMode else { return transcript }

        let normalized = DeterministicNormalizer.normalize(transcript, settings: cleanup)
        let baseline = RetractionHeuristics.resolve(normalized, enabled: cleanup.resolveRetractions)

        guard settings.llm.enabled, let provider = resolvedProvider() else { return baseline }
        guard !shouldSkipLLM(for: baseline, settings: cleanup) else { return baseline }
        let keyName = provider == .openai ? "OPENAI_API_KEY" : "GROQ_API_KEY"
        guard let key = environment[keyName], !key.isEmpty else { return baseline }

        let endpoint = provider == .openai
            ? "https://api.openai.com/v1/chat/completions"
            : "https://api.groq.com/openai/v1/chat/completions"
        let model = provider == .openai ? settings.llm.openAIModel : settings.llm.groqModel
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": prompt(for: cleanup)],
                ["role": "user", "content": baseline]
            ]
        ]
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DictationError.remoteService(String(data: data, encoding: .utf8) ?? "Text cleanup request failed.")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return baseline
        }

        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              TranscriptGuard.accepts(cleaned, comparedTo: baseline, settings: cleanup) else {
            return transcript
        }
        return cleaned
    }

    private func shouldSkipLLM(for text: String, settings: CleanupSettings) -> Bool {
        guard settings.skipLLMForSimpleClips else { return false }
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        return wordCount <= 12 && !RefinementSignals.needsLLM(text, settings: settings)
    }

    private func prompt(for settings: CleanupSettings) -> String {
        var instructions = [
            "Return only the cleaned dictation, never an answer, explanation, acknowledgement, or commentary.",
            "Never add facts, requests, examples, names, or meaning that the speaker did not say.",
            "Keep the speaker's intended wording and tone whenever possible.",
            "If an instruction is ambiguous, preserve the original wording rather than guessing."
        ]
        if settings.removeFillers {
            instructions.append("Remove only obvious spoken fillers and false starts, including um, uh, aaa, matlab, and filler-use basically or like. Keep meaningful uses of words such as like.")
        }
        if settings.resolveRetractions {
            instructions.append("Treat no no, sorry, I mean, and actually as correction markers. Keep the correction and remove exactly the retracted word, phrase, or sentence; later corrected wording wins.")
        }
        if settings.improveHinglish {
            instructions.append("For Hinglish, output clean grammatical English with correct tense and articles while preserving the speaker's exact intent and tone. Do not invent a translation for unclear words.")
        }
        if settings.formatLists {
            instructions.append("When the speaker clearly dictates points such as first, second, third, point one, or point two, format them as a real numbered or bulleted list. Do not create a list otherwise.")
        }
        return instructions.joined(separator: " ")
    }

    private func resolvedProvider() -> LLMProvider? {
        switch settings.llm.provider {
        case .none: return nil
        case .openai, .groq: return settings.llm.provider
        case .auto:
            if let key = environment["OPENAI_API_KEY"], !key.isEmpty { return .openai }
            if let key = environment["GROQ_API_KEY"], !key.isEmpty { return .groq }
            return nil
        }
    }
}
