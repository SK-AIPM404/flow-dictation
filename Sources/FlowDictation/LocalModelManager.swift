import CryptoKit
import Foundation

enum LocalModelError: LocalizedError {
    case downloadFailed(String)
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let message): return message
        case .checksumMismatch: return "The downloaded small English Whisper model failed its integrity check."
        }
    }
}

enum LocalModelManager {
    static let smallEnglishFilename = "ggml-small.en.bin"
    static let smallEnglishURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin")!
    static let smallEnglishSHA256 = "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"

    static var defaultModelURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport
            .appendingPathComponent("FlowDictation", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(smallEnglishFilename)
    }

    static func downloadSmallEnglishModel() async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: smallEnglishURL)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw LocalModelError.downloadFailed("Could not download the small English Whisper model.")
        }
        guard try sha256(of: temporaryURL) == smallEnglishSHA256 else {
            throw LocalModelError.checksumMismatch
        }

        let destination = defaultModelURL
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
