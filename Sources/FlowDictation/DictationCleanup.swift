import Foundation

enum DeterministicNormalizer {
    static func normalize(_ transcript: String, settings: CleanupSettings) -> String {
        guard settings.deterministicFormatting else { return transcript }
        var result = normalizeAcronyms(in: transcript)
        result = normalizeSpokenPunctuation(in: result)
        result = SpokenListFormatter.format(result, enabled: settings.formatLists)
        result = normalizeNumberWords(in: result)
        result = normalizeUnitsAndDates(in: result)
        result = normalizeWhitespace(in: result)
        return result
    }

    private static func normalizeAcronyms(in text: String) -> String {
        let replacements = [
            "kay pee eye": "KPI", "k p i": "KPI",
            "okay are": "OKR", "o k r": "OKR",
            "a p i": "API", "you i": "UI", "u i": "UI",
            "you ex": "UX", "u x": "UX", "r o i": "ROI",
            "g t m": "GTM", "b to b": "B2B", "b to c": "B2C"
        ]
        return replacements.reduce(text) { partial, replacement in
            partial.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: replacement.key))\\b",
                with: replacement.value,
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }

    private static func normalizeSpokenPunctuation(in text: String) -> String {
        let replacements = [
            "new paragraph": "\n\n",
            "new line": "\n",
            "full stop": ".",
            "question mark": "?",
            "exclamation mark": "!",
            "exclamation point": "!",
            "semicolon": ";",
            "colon": ":",
            "comma": ",",
            "period": "."
        ]
        var result = replacements.reduce(text) { partial, replacement in
            partial.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: replacement.key))\\b",
                with: replacement.value,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        result = result.replacingOccurrences(of: "\\s+([,.;:!?])", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "([,.;:!?])(?=[^\\s\\n])", with: "$1 ", options: .regularExpression)
        result = result.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        return result
    }

    private static func normalizeNumberWords(in text: String) -> String {
        let values: [String: Int] = [
            "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
            "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
            "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
            "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40,
            "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
        ]
        let scales: [String: Int] = ["hundred": 100, "thousand": 1_000, "million": 1_000_000]
        let pieces = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var index = 0

        while index < pieces.count {
            var cursor = index
            var current = 0
            var total = 0
            var sawNumber = false
            while cursor < pieces.count {
                let token = pieces[cursor]
                let normalized = token.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if let value = values[normalized] {
                    current += value
                    sawNumber = true
                } else if let scale = scales[normalized], sawNumber {
                    if scale == 100 {
                        current = max(1, current) * scale
                    } else {
                        total += max(1, current) * scale
                        current = 0
                    }
                } else if normalized == "and", sawNumber {
                    // Spoken number connector; it has no written representation here.
                } else {
                    break
                }
                cursor += 1
            }
            if sawNumber {
                let trailingPunctuation = String(pieces[cursor - 1].reversed().prefix { $0.isPunctuation }.reversed())
                output.append("\(total + current)\(trailingPunctuation)")
                index = cursor
            } else {
                output.append(pieces[index])
                index += 1
            }
        }
        return output.joined(separator: " ")
    }

    private static func normalizeUnitsAndDates(in text: String) -> String {
        var result = text
        let replacements = [
            ("\\b(\\d+(?:\\.\\d+)?)\\s*(?:percent|per cent)\\b", "$1%"),
            ("\\b(?:dollars?|usd)\\s*(\\d+(?:\\.\\d+)?)\\b", "$$1"),
            ("\\b(\\d+(?:\\.\\d+)?)\\s*(?:dollars?|usd)\\b", "$$1"),
            ("\\b(?:rupees?|inr)\\s*(\\d+(?:\\.\\d+)?)\\b", "INR $1"),
            ("\\b(\\d+(?:\\.\\d+)?)\\s*(?:rupees?|inr)\\b", "INR $1")
        ]
        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }

        let months = "January|February|March|April|May|June|July|August|September|October|November|December"
        result = result.replacingOccurrences(
            of: "\\b(\(months))\\s+(\\d{1,2})\\s+(\\d{4})\\b",
            with: "$1 $2, $3",
            options: [.regularExpression, .caseInsensitive]
        )
        return result
    }

    private static func normalizeWhitespace(in text: String) -> String {
        text
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SpokenListFormatter {
    private static let markerPattern = "(?i)\\b(first|second|third|fourth|fifth|point\\s+(?:one|two|three|four|five|1|2|3|4|5))\\b\\s*(?:is\\s+)?"

    static func format(_ transcript: String, enabled: Bool) -> String {
        guard enabled,
              let expression = try? NSRegularExpression(pattern: markerPattern) else {
            return transcript
        }
        let fullRange = NSRange(transcript.startIndex..., in: transcript)
        let matches = expression.matches(in: transcript, range: fullRange)
        guard matches.count >= 2 else { return transcript }

        var entries: [(number: Int, text: String)] = []
        for (index, match) in matches.enumerated() {
            let itemStart = match.range.location + match.range.length
            let itemEnd = index + 1 < matches.count ? matches[index + 1].range.location : fullRange.length
            guard let itemRange = Range(NSRange(location: itemStart, length: itemEnd - itemStart), in: transcript),
                  let markerRange = Range(match.range(at: 1), in: transcript) else {
                return transcript
            }
            let item = String(transcript[itemRange])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !item.isEmpty else { return transcript }
            entries.append((number: listNumber(String(transcript[markerRange])), text: item))
        }

        guard let firstMatch = matches.first,
              let preambleRange = Range(NSRange(location: 0, length: firstMatch.range.location), in: transcript) else {
            return transcript
        }
        let preamble = String(transcript[preambleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let list = entries.map { "\($0.number). \($0.text)" }.joined(separator: "\n")
        return preamble.isEmpty ? list : "\(preamble)\n\n\(list)"
    }

    private static func listNumber(_ marker: String) -> Int {
        switch marker.lowercased().replacingOccurrences(of: " ", with: "") {
        case "first", "pointone", "point1": return 1
        case "second", "pointtwo", "point2": return 2
        case "third", "pointthree", "point3": return 3
        case "fourth", "pointfour", "point4": return 4
        case "fifth", "pointfive", "point5": return 5
        default: return 1
        }
    }
}

enum RetractionHeuristics {
    static func resolve(_ transcript: String, enabled: Bool) -> String {
        guard enabled else { return transcript }
        let pattern = "(?is)^(.*?\\b(?:to|for|with|from)\\s+)[^,.!?]+?\\s*,?\\s*(?:no\\s+){1,2}(?:sorry\\s*,?\\s*)?(?:i\\s+mean\\s+)?([^,.!?]+)[.!?]?$"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: transcript, range: NSRange(transcript.startIndex..., in: transcript)),
              let prefixRange = Range(match.range(at: 1), in: transcript),
              let correctionRange = Range(match.range(at: 2), in: transcript) else {
            return transcript
        }
        return String(transcript[prefixRange]) + transcript[correctionRange].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RefinementSignals {
    static func needsLLM(_ text: String, settings: CleanupSettings) -> Bool {
        let lowercased = text.lowercased()
        let signals = [" um ", " uh ", " aaa ", " matlab ", " basically ", " no no ", " sorry ", " i mean ", " actually ", " first ", " second ", " point one", " point two", " hai ", " hain "]
        return signals.contains { lowercased.contains($0) }
    }
}

enum TranscriptGuard {
    static func accepts(_ candidate: String, comparedTo original: String, settings: CleanupSettings) -> Bool {
        let originalWords = words(in: original)
        let candidateWords = words(in: candidate)
        guard !candidateWords.isEmpty else { return false }
        guard !originalWords.isEmpty else { return true }
        let ratio = Double(candidateWords.count) / Double(originalWords.count)
        guard ratio >= settings.minimumOutputWordRatio, ratio <= settings.maximumOutputWordRatio else { return false }

        let distance = levenshtein(originalWords, candidateWords)
        let normalizedDistance = Double(distance) / Double(max(originalWords.count, candidateWords.count))
        return normalizedDistance <= settings.maximumEditDistanceRatio
    }

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func levenshtein(_ first: [String], _ second: [String]) -> Int {
        var previous = Array(0...second.count)
        for (firstIndex, firstWord) in first.enumerated() {
            var current = [firstIndex + 1]
            for (secondIndex, secondWord) in second.enumerated() {
                let substitution = previous[secondIndex] + (firstWord == secondWord ? 0 : 1)
                current.append(min(current[secondIndex] + 1, previous[secondIndex + 1] + 1, substitution))
            }
            previous = current
        }
        return previous[second.count]
    }
}
