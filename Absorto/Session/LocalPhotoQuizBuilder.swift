import Foundation

/// Builds a small multiple-choice quiz from OCR text — local heuristics only.
enum LocalPhotoQuizBuilder {
    private static let distractorBank = [
        "photosynthesis", "mitochondria", "polynomial", "derivative", "integral",
        "latency", "throughput", "recursion", "inheritance", "entropy",
        "hypothesis", "variable", "coefficient", "algorithm", "protocol",
        "diffusion", "catalyst", "amplitude", "frequency", "gradient"
    ]

    /// Returns 3 MC questions, or nil if OCR signal is too weak.
    static func build(sessionId: UUID, topic: String, ocr: StudyOCRService.Result) -> [Question]? {
        let keywords = StudyOCRService.keywords(from: ocr.words)
        guard keywords.count >= StudyOCRService.minimumKeywordCount else { return nil }

        let k0 = keywords[0]
        let k1 = keywords[safe: 1] ?? keywords[0]
        let k2 = keywords[safe: 2] ?? keywords[0]

        let clozeLine = ocr.lines.first(where: { line in
            let lower = line.lowercased()
            return lower.contains(k2) && line.split(separator: " ").count >= 4 && line.count <= 120
        })
        let clozeStem: String
        if let line = clozeLine {
            clozeStem = "Fill the blank from your photo:\n“\(blanking(line, word: k2))”"
        } else {
            clozeStem = "Which word from your photo best fits studying \(topic.isEmpty ? "this material" : topic)?"
        }

        return [
            makeQuestion(
                sessionId: sessionId,
                hotspot: "Term from photo",
                text: "Which term appears in your study photo?",
                correct: display(k0),
                wrongPool: keywords + distractorBank,
                excluding: [k0]
            ),
            makeQuestion(
                sessionId: sessionId,
                hotspot: "Second term",
                text: "Which other term also appears in your notes/screenshot?",
                correct: display(k1),
                wrongPool: keywords + distractorBank,
                excluding: [k0, k1]
            ),
            makeQuestion(
                sessionId: sessionId,
                hotspot: "Cloze",
                text: clozeStem,
                correct: display(k2),
                wrongPool: keywords + distractorBank,
                excluding: [k2]
            )
        ]
    }

    private static func makeQuestion(
        sessionId: UUID,
        hotspot: String,
        text: String,
        correct: String,
        wrongPool: [String],
        excluding: [String]
    ) -> Question {
        let options = shuffledOptions(correct: correct, wrongPool: wrongPool, excluding: excluding)
        let correctIndex = options.firstIndex(of: correct) ?? 0
        return Question(
            sessionId: sessionId,
            hotspot: hotspot,
            text: text,
            kind: .multipleChoice,
            options: options,
            correctOptionIndex: correctIndex
        )
    }

    private static func shuffledOptions(correct: String, wrongPool: [String], excluding: [String]) -> [String] {
        let exclude = Set(excluding.map { $0.lowercased() } + [correct.lowercased()])
        var wrongs: [String] = []
        for candidate in wrongPool {
            let d = display(candidate)
            guard !exclude.contains(d.lowercased()) else { continue }
            if !wrongs.contains(where: { $0.lowercased() == d.lowercased() }) {
                wrongs.append(d)
            }
            if wrongs.count == 3 { break }
        }
        while wrongs.count < 3 {
            let pad = distractorBank[wrongs.count % distractorBank.count]
            let d = display(pad)
            if !exclude.contains(d.lowercased()), !wrongs.contains(where: { $0.lowercased() == d.lowercased() }) {
                wrongs.append(d)
            } else {
                wrongs.append("Concept \(wrongs.count + 1)")
            }
        }
        var options = [correct] + Array(wrongs.prefix(3))
        options.shuffle()
        return options
    }

    private static func blanking(_ line: String, word: String) -> String {
        guard let range = line.range(of: word, options: .caseInsensitive) else {
            return line
        }
        return line.replacingCharacters(in: range, with: "______")
    }

    private static func display(_ word: String) -> String {
        guard let first = word.first else { return word }
        return String(first).uppercased() + word.dropFirst()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
