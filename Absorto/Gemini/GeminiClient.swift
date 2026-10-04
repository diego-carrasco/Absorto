import Foundation
import AppKit

/// Gemini REST client with structured JSON output, backoff, and offline-friendly rate-limit gates.
actor GeminiClient {
    struct DriftClassification: Equatable {
        var isFalseAlarm: Bool
        var category: DriftCategory
        var severity: Int
        var studying: String
        var nudgeText: String
    }

    struct WindowJudgment: Equatable {
        var onTask: String // yes | no | unsure
        var reason: String
    }

    private let session: URLSession
    private let apiKeyOverride: String?
    private let modelOverride: String?

    /// When set, callers should prefer local fallbacks instead of hammering the API.
    private var rateLimitedUntil: Date?
    private var consecutiveTransientFailures = 0
    private var lastCallAt: Date?
    private var windowTitleCache: [String: WindowJudgment] = [:]

    /// Minimum spacing between any Gemini generate calls (free-tier friendly).
    private let minCallSpacing: TimeInterval = 2.5

    init(apiKey: String? = nil, model: String? = nil) {
        self.apiKeyOverride = apiKey
        self.modelOverride = model
        self.session = URLSession(configuration: .ephemeral)
    }

    private var apiKey: String { apiKeyOverride ?? AppConfig.geminiAPIKey }
    private var model: String { modelOverride ?? AppConfig.geminiModel }

    var isConfigured: Bool {
        let key = apiKey
        return !key.isEmpty && key != "YOUR_GEMINI_API_KEY_HERE"
    }

    /// True while we should avoid remote calls and use offline fallbacks.
    var isRateLimited: Bool {
        guard let until = rateLimitedUntil else { return false }
        return Date() < until
    }

    var rateLimitStatusText: String? {
        guard isRateLimited else { return nil }
        return "Gemini rate-limited — using offline fallback"
    }

    // MARK: 1. Classify drift + nudge

    func classifyDrift(
        webcamJPEG: Data,
        screenJPEG: Data?,
        rule: DriftRule
    ) async throws -> DriftClassification {
        try throwIfRateLimited()

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "is_false_alarm": ["type": "boolean"],
                "category": [
                    "type": "string",
                    "enum": ["phone", "away", "looking_elsewhere", "tired", "other"]
                ],
                "severity": ["type": "integer"],
                "studying": ["type": "string"],
                "nudge_text": ["type": "string"]
            ],
            "required": ["is_false_alarm", "category", "severity", "studying", "nudge_text"]
        ]

        let hasScreen = screenJPEG != nil
        let prompt = """
        You are the accountability coach for a solo study session (Proof-of-Work Pomodoro).
        An on-device detector fired rule: \(rule.rawValue).
        Image 1 is the webcam.\(hasScreen ? " Image 2 is the screen at that moment." : " No screen image was available — do not invent screen contents.")

        Decide if this is a real distraction or a false alarm (thinking pose, blink, reading lower on the display, adjusting posture).

        Category rules (strict):
        - phone: ONLY if a phone is clearly visible in the webcam. Never assume phone from head_down, head_turned, or no_face alone.
        - looking_elsewhere: default for head_turned (yaw) when the person is still at the desk.
        - away: default for no_face when they have left the frame.
        - tired: yawning / eyes closing without leaving.
        - other: head_down without a visible phone (notes on desk, stretching) if it is still a real distraction.

        Nudge rules:
        - Match the evidence. Looking right/left → eyes-forward nudge, NOT "put your phone down".
        - head_down without a visible phone → "eyes up" / stay with the material — never mention a phone.
        - Name the study material when the screen image shows it; otherwise keep the nudge generic.

        If real: category, severity 1-5, what they were studying (from the screen if present), and a short
        personal spoken nudge (one sentence).
        Return JSON only.
        """

        var images = [webcamJPEG]
        if let screenJPEG { images.append(screenJPEG) }

        let json = try await generateJSON(
            prompt: prompt,
            images: images,
            schema: schema
        )

        let categoryRaw = json["category"] as? String ?? "other"
        var category = DriftCategory(rawValue: categoryRaw) ?? .other
        let severity = max(1, min(5, intValue(json["severity"]) ?? 3))
        let isFalse = json["is_false_alarm"] as? Bool ?? false
        var nudge = json["nudge_text"] as? String ?? "Eyes back on your notes."

        // Webcam-only / rule-based guardrails: never invent phone from pose alone.
        if !isFalse {
            category = Self.sanitizeCategory(category, rule: rule, hasScreen: hasScreen)
            nudge = Self.sanitizeNudge(nudge, category: category, rule: rule)
        }

        return DriftClassification(
            isFalseAlarm: isFalse,
            category: isFalse ? .falseAlarm : category,
            severity: severity,
            studying: json["studying"] as? String ?? "",
            nudgeText: nudge
        )
    }

    // MARK: 2. Window title check

    func checkWindowTitle(appName: String, windowTitle: String, topic: String) async throws -> WindowJudgment {
        let key = "\(appName.lowercased())|\(windowTitle.lowercased())|\(topic.lowercased())"
        if let cached = windowTitleCache[key] {
            return cached
        }

        try throwIfRateLimited()

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "on_task": ["type": "string", "enum": ["yes", "no", "unsure"]],
                "reason": ["type": "string"]
            ],
            "required": ["on_task", "reason"]
        ]

        let prompt = """
        Study topic for this session: \(topic.isEmpty ? "(unknown — infer carefully)" : topic)
        Front app: \(appName)
        Window/tab title: \(windowTitle)
        Is this on-task for studying that topic? Cat videos, social feeds, shopping, games = no.
        Lecture slides, docs, textbooks, course pages, IDE for coursework = yes.
        If unsure from the title alone, return unsure (do not guess "no").
        Return JSON only.
        """

        let json = try await generateJSON(prompt: prompt, images: [], schema: schema)
        let judgment = WindowJudgment(
            onTask: json["on_task"] as? String ?? "unsure",
            reason: json["reason"] as? String ?? ""
        )
        windowTitleCache[key] = judgment
        return judgment
    }

    // MARK: 3. Spoken nudge (TTS) — caller falls back to AVSpeech

    func synthesizeSpeech(nudgeText: String) async throws -> Data? {
        _ = nudgeText
        return nil
    }

    // MARK: 4. Focus check (attention summary + useful recall)

    func buildAttentionMap(
        drifts: [DriftEvent],
        startScreenJPEG: Data?,
        endScreenJPEG: Data?,
        topicHint: String
    ) async throws -> AttentionMapResult {
        try throwIfRateLimited()

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "topic": ["type": "string"],
                "summary": ["type": "string"],
                "hotspots": [
                    "type": "array",
                    "items": ["type": "string"]
                ],
                "questions": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "kind": [
                                "type": "string",
                                "enum": ["multiple_choice", "teach_back"]
                            ],
                            "hotspot": ["type": "string"],
                            "text": ["type": "string"],
                            "options": [
                                "type": "array",
                                "items": ["type": "string"]
                            ],
                            "correct_option_index": ["type": "integer"]
                        ],
                        "required": ["kind", "hotspot", "text"]
                    ]
                ]
            ],
            "required": ["topic", "summary", "hotspots", "questions"]
        ]

        let registry = drifts
            .filter { !$0.falseAlarm }
            .map { e in
                "- t=\(Int(e.time.timeIntervalSince1970)) source=\(e.source.rawValue) rule=\(e.rule.rawValue) cat=\(e.category?.rawValue ?? "?") sev=\(e.severity) studying=\(e.studying ?? "")"
            }
            .joined(separator: "\n")

        let prompt = """
        You are building a Focus Check for a finished study session — useful active recall, not busywork.
        Topic hint: \(topicHint)
        Drift registry:
        \(registry.isEmpty ? "(no confirmed drifts)" : registry)
        Screen images (start then end) may be attached — ground questions in what is actually visible.

        Return:
        - topic
        - summary: where attention broke (1-2 sentences)
        - hotspots: 2-4 short phrases from the material
        - questions: exactly 3 items:
          1) multiple_choice about a concrete fact/concept on the screen (4 options, correct_option_index 0-3)
          2) multiple_choice about a second concrete detail (4 options, correct_option_index 0-3)
          3) teach_back: ask them to explain one idea in their own words in 1-2 sentences (no options)

        Make wrong MC options plausible. Prefer drift hotspots when present.
        Return JSON only.
        """

        var images: [Data] = []
        if let s = startScreenJPEG { images.append(s) }
        if let e = endScreenJPEG { images.append(e) }

        let json = try await generateJSON(prompt: prompt, images: images, schema: schema)
        let sessionId = drifts.first?.sessionId ?? UUID()
        let qdicts = json["questions"] as? [[String: Any]] ?? []
        let questions = qdicts.prefix(3).enumerated().map { idx, q -> Question in
            let kindRaw = q["kind"] as? String ?? (idx < 2 ? "multiple_choice" : "teach_back")
            let kind = QuestionKind(rawValue: kindRaw) ?? (idx < 2 ? .multipleChoice : .teachBack)
            let options = q["options"] as? [String] ?? []
            return Question(
                sessionId: sessionId,
                hotspot: q["hotspot"] as? String ?? "general",
                text: q["text"] as? String ?? "What were you studying?",
                kind: kind,
                options: options,
                correctOptionIndex: intValue(q["correct_option_index"])
            )
        }

        return AttentionMapResult(
            topic: json["topic"] as? String ?? topicHint,
            summary: json["summary"] as? String ?? "Session complete.",
            hotspots: json["hotspots"] as? [String] ?? [],
            questions: Array(questions)
        )
    }

    // MARK: 5. Grade answers (MC local-friendly + teach-back coaching)

    func gradeAnswers(questions: [Question]) async throws -> GradeResult {
        // Grade multiple-choice locally when we have an answer key.
        var scores: [Bool] = Array(repeating: false, count: questions.count)
        var feedback: [String] = Array(repeating: "", count: questions.count)
        var needsTeachBack: [(Int, Question)] = []

        for (i, q) in questions.enumerated() {
            switch q.kind {
            case .multipleChoice:
                if let selected = q.selectedOptionIndex, let correct = q.correctOptionIndex {
                    let ok = selected == correct
                    scores[i] = ok
                    if ok {
                        feedback[i] = "Correct."
                    } else if correct < q.options.count {
                        feedback[i] = "Not quite — look back at: \(q.options[correct])"
                    } else {
                        feedback[i] = "Not quite — revisit \(q.hotspot)."
                    }
                } else {
                    scores[i] = false
                    feedback[i] = "No selection — mark for review."
                }
            case .teachBack:
                needsTeachBack.append((i, q))
            }
        }

        if !needsTeachBack.isEmpty {
            if isRateLimited {
                return localTeachBackGrade(questions: questions, scores: scores, feedback: feedback)
            }

            let schema: [String: Any] = [
                "type": "object",
                "properties": [
                    "results": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "index": ["type": "integer"],
                                "correct": ["type": "boolean"],
                                "feedback": ["type": "string"]
                            ],
                            "required": ["index", "correct", "feedback"]
                        ]
                    ],
                    "weak_topic": ["type": "string"],
                    "next_focus": ["type": "string"]
                ],
                "required": ["results", "weak_topic", "next_focus"]
            ]

            let qa = needsTeachBack.map { i, q in
                "INDEX \(i) [\(q.hotspot)]: \(q.text)\nSTUDENT: \(q.myAnswer)"
            }.joined(separator: "\n\n")

            let prompt = """
            Grade these teach-back answers from a study Focus Check.
            Be a tough but fair tutor: correct if they capture the core idea in their own words.
            Feedback should be one concrete coaching sentence (what to restudy), not generic praise.
            \(qa)
            Return JSON with results (index/correct/feedback), weak_topic, and next_focus (one phrase for the next pomodoro).
            """

            do {
                let json = try await generateJSON(prompt: prompt, images: [], schema: schema)
                let results = json["results"] as? [[String: Any]] ?? []
                for r in results {
                    guard let idx = intValue(r["index"]), questions.indices.contains(idx) else { continue }
                    scores[idx] = r["correct"] as? Bool ?? false
                    feedback[idx] = r["feedback"] as? String ?? ""
                }
                let correctCount = scores.filter { $0 }.count
                let overall = questions.isEmpty ? 0 : Double(correctCount) / Double(questions.count)
                let weak = (json["weak_topic"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (json["next_focus"] as? String)
                    ?? ""
                return GradeResult(
                    scorePerQuestion: scores,
                    feedback: feedback,
                    weakTopic: weak,
                    overallScore: overall
                )
            } catch is GeminiError {
                return localTeachBackGrade(questions: questions, scores: scores, feedback: feedback)
            }
        }

        let correctCount = scores.filter { $0 }.count
        let overall = questions.isEmpty ? 0 : Double(correctCount) / Double(questions.count)
        let weak = questions.enumerated().first(where: { !scores[$0.offset] })?.element.hotspot ?? ""
        return GradeResult(
            scorePerQuestion: scores,
            feedback: feedback,
            weakTopic: weak,
            overallScore: overall
        )
    }

    /// Infer topic from a single start-of-session screen frame.
    func inferTopic(screenJPEG: Data) async throws -> String {
        try throwIfRateLimited()
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "topic": ["type": "string"]
            ],
            "required": ["topic"]
        ]
        let prompt = """
        Look at this study screen. Return a short topic label (course + subject), e.g. "CMPT 371 — queueing delay".
        JSON only.
        """
        let json = try await generateJSON(prompt: prompt, images: [screenJPEG], schema: schema)
        return json["topic"] as? String ?? "Study session"
    }

    /// Lightweight connectivity check for diagnostics. Skips when rate-limited.
    func ping() async throws -> String {
        if isRateLimited {
            throw GeminiError.rateLimited(retryAfter: rateLimitedUntil.map { $0.timeIntervalSinceNow } ?? 30)
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["ok": ["type": "boolean"]],
            "required": ["ok"]
        ]
        let json = try await generateJSON(
            prompt: "Return JSON {\"ok\": true}",
            images: [],
            schema: schema
        )
        return (json["ok"] as? Bool) == true ? "ok" : "unexpected"
    }

    // MARK: - Transport

    private func throwIfRateLimited() throws {
        if let until = rateLimitedUntil, Date() < until {
            throw GeminiError.rateLimited(retryAfter: until.timeIntervalSinceNow)
        }
    }

    private func generateJSON(
        prompt: String,
        images: [Data],
        schema: [String: Any]
    ) async throws -> [String: Any] {
        guard isConfigured else {
            throw GeminiError.missingAPIKey
        }
        try throwIfRateLimited()

        // Coalesce rapid callers (window titles + drift fires).
        if let last = lastCallAt {
            let gap = Date().timeIntervalSince(last)
            if gap < minCallSpacing {
                try await Task.sleep(nanoseconds: UInt64((minCallSpacing - gap) * 1_000_000_000))
            }
        }

        var lastError: Error = GeminiError.badResponse
        let maxAttempts = 3

        for attempt in 0..<maxAttempts {
            do {
                let json = try await performGenerateJSON(prompt: prompt, images: images, schema: schema)
                consecutiveTransientFailures = 0
                lastCallAt = Date()
                return json
            } catch let error as GeminiError {
                lastError = error
                switch error {
                case .http(let code, let body) where code == 429 || code == 503:
                    consecutiveTransientFailures += 1
                    let retryAfter = Self.parseRetryAfter(from: body) ?? Self.backoffSeconds(attempt: attempt, failures: consecutiveTransientFailures)
                    rateLimitedUntil = Date().addingTimeInterval(retryAfter)
                    lastCallAt = Date()
                    if attempt + 1 >= maxAttempts {
                        throw GeminiError.rateLimited(retryAfter: retryAfter)
                    }
                    try await Task.sleep(nanoseconds: UInt64(min(retryAfter, 8) * 1_000_000_000))
                case .http(let code, _) where (500...599).contains(code):
                    consecutiveTransientFailures += 1
                    let delay = Self.backoffSeconds(attempt: attempt, failures: consecutiveTransientFailures)
                    if attempt + 1 >= maxAttempts {
                        rateLimitedUntil = Date().addingTimeInterval(delay)
                        throw error
                    }
                    try await Task.sleep(nanoseconds: UInt64(min(delay, 6) * 1_000_000_000))
                default:
                    lastCallAt = Date()
                    throw error
                }
            } catch {
                lastCallAt = Date()
                throw error
            }
        }

        throw lastError
    }

    private func performGenerateJSON(
        prompt: String,
        images: [Data],
        schema: [String: Any]
    ) async throws -> [String: Any] {
        var parts: [[String: Any]] = [["text": prompt]]
        for data in images {
            let b64 = data.base64EncodedString()
            parts.append([
                "inlineData": [
                    "mimeType": "image/jpeg",
                    "data": b64
                ]
            ])
        }

        let body: [String: Any] = [
            "contents": [
                ["role": "user", "parts": parts]
            ],
            "generationConfig": [
                "temperature": 0.2,
                "responseMimeType": "application/json",
                "responseSchema": schema
            ]
        ]

        let key = apiKey
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(key)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.badResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            // Never echo API keys if Google reflects the request URL.
            let scrubbed = text.replacingOccurrences(
                of: #"key=[^&\s\"]+"#,
                with: "key=***",
                options: .regularExpression
            )
            throw GeminiError.http(http.statusCode, scrubbed)
        }

        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let candidates = root?["candidates"] as? [[String: Any]]
        let content = candidates?.first?["content"] as? [String: Any]
        let outParts = content?["parts"] as? [[String: Any]]
        let text = outParts?.first?["text"] as? String ?? ""

        guard let textData = text.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: textData) as? [String: Any] else {
            throw GeminiError.parseFailed(text)
        }
        return json
    }

    private func localTeachBackGrade(
        questions: [Question],
        scores: [Bool],
        feedback: [String]
    ) -> GradeResult {
        var scores = scores
        var feedback = feedback
        for (i, q) in questions.enumerated() where q.kind == .teachBack {
            let ok = !q.myAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            scores[i] = ok
            feedback[i] = ok ? "Answer recorded — revisit this on the next block." : "No teach-back — mark for review."
        }
        let correctCount = scores.filter { $0 }.count
        let overall = questions.isEmpty ? 0 : Double(correctCount) / Double(questions.count)
        let weak = questions.enumerated().first(where: { !scores[$0.offset] })?.element.hotspot ?? ""
        return GradeResult(
            scorePerQuestion: scores,
            feedback: feedback,
            weakTopic: weak,
            overallScore: overall
        )
    }

    private static func sanitizeCategory(_ category: DriftCategory, rule: DriftRule, hasScreen: Bool) -> DriftCategory {
        _ = hasScreen
        // Pose-only rules must not invent a phone. head_down may still be phone if the webcam shows one.
        if category == .phone {
            switch rule {
            case .headTurned, .offTaskWindow:
                return .lookingElsewhere
            case .noFace:
                return .away
            case .headDown:
                return .phone
            }
        }
        switch rule {
        case .headTurned where category == .away:
            return .lookingElsewhere
        case .noFace where category == .lookingElsewhere || category == .other:
            return .away
        default:
            return category
        }
    }

    private static func sanitizeNudge(_ nudge: String, category: DriftCategory, rule: DriftRule) -> String {
        let lower = nudge.lowercased()
        let mentionsPhone = lower.contains("phone")
        if mentionsPhone && category != .phone {
            switch rule {
            case .headTurned:
                return "Eyes forward — stay with your work."
            case .headDown:
                return "Eyes up — stay with your material."
            case .noFace:
                return "Come back to your desk."
            case .offTaskWindow:
                return "That tab is off-task — back to your material."
            }
        }
        if mentionsPhone && rule == .headTurned {
            return "Eyes forward — stay with your work."
        }
        return nudge
    }

    private static func parseRetryAfter(from body: String) -> TimeInterval? {
        // Google sometimes embeds retryDelay like "RetryInfo","retryDelay":"8s"
        if let range = body.range(of: #"retryDelay"\s*:\s*"(\d+)(\.\d+)?s""#, options: .regularExpression) {
            let snippet = String(body[range])
            let digits = snippet.filter { $0.isNumber || $0 == "." }
            if let value = Double(digits), value > 0 { return min(value, 120) }
        }
        if let range = body.range(of: #"Please retry in\s+(\d+(\.\d+)?)s"#, options: [.regularExpression, .caseInsensitive]) {
            let snippet = String(body[range])
            let digits = snippet.filter { $0.isNumber || $0 == "." }
            if let value = Double(digits), value > 0 { return min(value, 120) }
        }
        return nil
    }

    private static func backoffSeconds(attempt: Int, failures: Int) -> TimeInterval {
        let base = pow(2.0, Double(attempt)) * 2.0 // 2, 4, 8…
        let scaled = base * Double(min(failures, 4))
        return min(60, max(4, scaled))
    }

    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return Int(d) }
        return nil
    }
}

enum GeminiError: LocalizedError {
    case missingAPIKey
    case badResponse
    case http(Int, String)
    case parseFailed(String)
    case rateLimited(retryAfter: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your Gemini API key to Config.plist (see Config.example.plist)."
        case .badResponse:
            return "Empty response from Gemini."
        case .http(let code, let body):
            if code == 429 || code == 503 {
                return "Gemini temporarily unavailable (HTTP \(code)). Using offline fallback."
            }
            return "Gemini HTTP \(code): \(body.prefix(160))"
        case .parseFailed(let t):
            return "Could not parse Gemini JSON: \(t.prefix(160))"
        case .rateLimited(let retryAfter):
            return "Gemini rate-limited — using offline fallback (\(Int(retryAfter))s)."
        }
    }

    var isRateLimitLike: Bool {
        switch self {
        case .rateLimited: return true
        case .http(let code, _) where code == 429 || code == 503: return true
        default: return false
        }
    }
}

enum ImageCodec {
    static func jpeg(from image: NSImage, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image.tiffRepresentation.flatMap { tiff in
                NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [.compressionFactor: quality])
            }
        }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let scale = min(1, maxDimension / max(w, h))
        let size = NSSize(width: w * scale, height: h * scale)
        let resized = NSImage(size: size)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .medium
        image.draw(in: NSRect(origin: .zero, size: size))
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    static func jpeg(from cgImage: CGImage, quality: CGFloat = 0.7) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
