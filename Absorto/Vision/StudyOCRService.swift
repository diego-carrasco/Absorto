import AppKit
import Vision

/// On-device text recognition for study-photo quizzes (no network / no Gemini).
enum StudyOCRService {
    struct Result: Sendable {
        var lines: [String]
        var words: [String]
    }

    /// Minimum useful signal before we trust OCR for a quiz.
    static let minimumKeywordCount = 4

    static func recognize(from image: NSImage) async -> Result {
        guard let cg = cgImage(from: image) else {
            return Result(lines: [], words: [])
        }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                var lines: [String] = []
                var words: [String] = []

                for obs in observations {
                    guard let top = obs.topCandidates(1).first, top.confidence >= 0.35 else { continue }
                    let line = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { continue }
                    lines.append(line)
                    for token in tokenize(line) {
                        words.append(token)
                    }
                }

                continuation.resume(returning: Result(lines: lines, words: words))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if #available(macOS 13.0, *) {
                request.automaticallyDetectsLanguage = true
            }

            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: Result(lines: [], words: []))
            }
        }
    }

    static func keywords(from words: [String], limit: Int = 24) -> [String] {
        let stop: Set<String> = [
            "the", "and", "for", "that", "with", "this", "from", "your", "have", "are",
            "was", "were", "been", "being", "will", "would", "could", "should", "about",
            "into", "then", "than", "them", "they", "their", "what", "when", "where",
            "which", "while", "each", "other", "some", "such", "only", "also", "just",
            "like", "over", "after", "before", "between", "through", "during", "under",
            "again", "further", "once", "here", "there", "these", "those", "study",
            "notes", "page", "slide", "chapter", "figure", "table", "using", "used"
        ]

        var counts: [String: Int] = [:]
        for w in words {
            let lower = w.lowercased()
            guard lower.count >= 4, !stop.contains(lower), lower.rangeOfCharacter(from: .letters) != nil else {
                continue
            }
            counts[lower, default: 0] += 1
        }

        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(limit)
            .map(\.key)
    }

    private static func tokenize(_ line: String) -> [String] {
        line.split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cg
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.cgImage
    }
}
