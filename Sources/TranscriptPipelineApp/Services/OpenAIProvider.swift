import Foundation

struct OpenAIProvider: TranscriptionProvider, InsightProvider, ChatProvider {
    let providerID = "openai"
    let capabilities = ProviderCapabilities(
        acceptsAudio: true,
        supportsDiarization: true,
        supportsStructuredOutput: true,
        maximumUploadBytes: AppConfiguration.maximumUploadBytes,
        maximumKnownSpeakers: 4
    )

    private let baseURL: URL
    private let session: URLSession

    init(
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func validateAPIKey(_ apiKey: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        addHeaders(to: &request, apiKey: apiKey)
        _ = try await send(request)
    }

    func transcribe(
        part: PreparedAudioPart,
        languageHint: LanguageHint,
        knownSpeakers: [KnownSpeakerReference],
        apiKey: String
    ) async throws -> TranscriptionResult {
        let fileBytes = try part.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileBytes <= capabilities.maximumUploadBytes else {
            throw ProviderError.uploadTooLarge(fileBytes)
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptPipelineMultipart-\(UUID().uuidString).body")
        let multipart = try MultipartFormFile(boundary: boundary, outputURL: bodyURL)
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        try multipart.addField(name: "model", value: AppConfiguration.transcriptionModel)
        try multipart.addField(name: "response_format", value: "diarized_json")
        try multipart.addField(name: "chunking_strategy", value: "auto")
        if let language = languageHint.apiValue {
            try multipart.addField(name: "language", value: language)
        }
        for reference in knownSpeakers.prefix(capabilities.maximumKnownSpeakers) {
            try multipart.addField(name: "known_speaker_names[]", value: reference.name)
            let referenceData = try Data(contentsOf: reference.audioURL)
            let mime = Self.mimeType(for: reference.audioURL)
            try multipart.addField(
                name: "known_speaker_references[]",
                value: "data:\(mime);base64,\(referenceData.base64EncodedString())"
            )
        }
        try multipart.addFile(
            name: "file",
            filename: part.fileURL.lastPathComponent,
            mimeType: Self.mimeType(for: part.fileURL),
            fileURL: part.fileURL
        )
        try multipart.finalize()

        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15 * 60
        addHeaders(to: &request, apiKey: apiKey)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let data = try await send(request, uploadFileURL: bodyURL)
        let wire = try JSONDecoder().decode(TranscriptionWireResponse.self, from: data)
        let segments = wire.segments.map { segment in
            TranscriptSegmentValue(
                speakerID: segment.speaker ?? "Speaker",
                startSeconds: segment.start,
                endSeconds: segment.end,
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return TranscriptionResult(
            segments: segments,
            detectedLanguage: wire.language,
            usage: wire.usage?.domain ?? .zero,
            rawResponse: data
        )
    }

    func generateAnalysis(
        transcript: [TranscriptSegmentValue],
        speakers: [String: String],
        template: AnalysisTemplateDefinition,
        model: String,
        apiKey: String
    ) async throws -> (AnalysisDocument, TokenUsage) {
        guard !transcript.isEmpty else { throw ProviderError.refused("The transcript is empty.") }
        let transcriptText = TranscriptFormatter.providerText(segments: transcript, speakers: speakers)
        let instructions = """
        You create faithful notes from a speaker-labelled transcript. Use only information present in the transcript.
        Distinguish discussion, proposals, and confirmed decisions. Never invent owners, due dates, or facts.
        Every factual item, decision, action, and open question must cite one or more exact segment UUIDs from the transcript.
        If a field is unknown, use an empty string. Keep the original language unless the user template clearly asks otherwise.

        Template: \(template.name)
        Template instructions: \(template.instructions)
        Suggested sections: \(template.sectionGuidance.joined(separator: ", "))
        """
        let body = try Self.responsesBody(
            model: model,
            instructions: instructions,
            input: "Recording transcript:\n\n\(transcriptText)",
            schemaName: "meeting_analysis",
            schema: Self.analysisSchema
        )
        let request = try responsesRequest(body: body, apiKey: apiKey)
        let data = try await send(request)
        let envelope = try JSONDecoder().decode(ResponsesWireEnvelope.self, from: data)
        let text = try envelope.outputText()
        let wire = try JSONDecoder().decode(AnalysisWire.self, from: Data(text.utf8))
        let lookup = Dictionary(uniqueKeysWithValues: transcript.map { ($0.id.uuidString, $0) })
        return (wire.domain(using: lookup), envelope.usage?.domain ?? .zero)
    }

    func answer(
        question: String,
        transcript: [TranscriptSegmentValue],
        speakers: [String: String],
        history: [(ChatRole, String)],
        model: String,
        apiKey: String
    ) async throws -> ChatAnswer {
        let transcriptText = TranscriptFormatter.providerText(segments: transcript, speakers: speakers)
        let recentHistory = history.suffix(12).map { "\($0.0.rawValue.capitalized): \($0.1)" }.joined(separator: "\n")
        let input = """
        Recording transcript:
        \(transcriptText)

        Recent local chat:
        \(recentHistory.isEmpty ? "No previous messages." : recentHistory)

        Question: \(question)
        """
        let instructions = """
        Answer only from the supplied recording transcript. Be concise and direct.
        Cite exact segment UUIDs supporting the answer. If the answer is absent or uncertain, say that plainly.
        Do not use outside knowledge and do not treat prior chat claims as transcript evidence.
        """
        let body = try Self.responsesBody(
            model: model,
            instructions: instructions,
            input: input,
            schemaName: "grounded_chat_answer",
            schema: Self.chatSchema
        )
        let request = try responsesRequest(body: body, apiKey: apiKey)
        let data = try await send(request)
        let envelope = try JSONDecoder().decode(ResponsesWireEnvelope.self, from: data)
        let text = try envelope.outputText()
        let wire = try JSONDecoder().decode(ChatWire.self, from: Data(text.utf8))
        let lookup = Dictionary(uniqueKeysWithValues: transcript.map { ($0.id.uuidString, $0) })
        return ChatAnswer(
            answer: wire.answer,
            citations: Self.resolveCitations(wire.segmentIDs, lookup: lookup),
            usage: envelope.usage?.domain ?? .zero
        )
    }

    static func responsesBody(
        model: String,
        instructions: String,
        input: String,
        schemaName: String,
        schema: [String: Any]
    ) throws -> Data {
        let object: [String: Any] = [
            "model": model,
            "store": false,
            "reasoning": ["effort": "low"],
            "instructions": instructions,
            "input": input,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": schemaName,
                    "strict": true,
                    "schema": schema
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func responsesRequest(body: Data, apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10 * 60
        addHeaders(to: &request, apiKey: apiKey)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private func addHeaders(to request: inout URLRequest, apiKey: String) {
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("TranscriptPipeline/1.2", forHTTPHeaderField: "User-Agent")
    }

    private func send(_ request: URLRequest, uploadFileURL: URL? = nil) async throws -> Data {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let result: (Data, URLResponse)
                if let uploadFileURL {
                    result = try await session.upload(for: request, fromFile: uploadFileURL)
                } else {
                    result = try await session.data(for: request)
                }
                let (data, response) = result
                guard let http = response as? HTTPURLResponse else { throw ProviderError.unsupportedResponse }
                if (200..<300).contains(http.statusCode) { return data }

                let message = (try? JSONDecoder().decode(OpenAIWireError.self, from: data).error.message)
                    ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                switch http.statusCode {
                case 401:
                    throw ProviderError.invalidAPIKey
                case 429:
                    let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                    if attempt < 2 {
                        try await Task.sleep(for: .seconds(retryAfter ?? pow(2, Double(attempt))))
                        continue
                    }
                    throw ProviderError.rateLimited(retryAfter: retryAfter)
                case 500...599 where attempt < 2:
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    continue
                default:
                    throw ProviderError.api(status: http.statusCode, message: String(message.prefix(500)))
                }
            } catch let error as ProviderError {
                throw error
            } catch {
                lastError = error
                if attempt < 2 {
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                }
            }
        }
        throw ProviderError.transport(lastError?.localizedDescription ?? "Unknown transport failure")
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3", "mpga", "mpeg": "audio/mpeg"
        case "mp4": "audio/mp4"
        case "m4a": "audio/m4a"
        case "wav": "audio/wav"
        case "webm": "audio/webm"
        default: "application/octet-stream"
        }
    }

    static func resolveCitations(
        _ ids: [String],
        lookup: [String: TranscriptSegmentValue]
    ) -> [EvidenceCitation] {
        var seen = Set<String>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted, let segment = lookup[id] else { return nil }
            return EvidenceCitation(
                segmentID: segment.id,
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds
            )
        }
    }

    static var analysisSchema: [String: Any] {
        let citedItem: [String: Any] = [
            "type": "object",
            "properties": [
                "text": ["type": "string"],
                "segment_ids": ["type": "array", "items": ["type": "string"]]
            ],
            "required": ["text", "segment_ids"],
            "additionalProperties": false
        ]
        let section: [String: Any] = [
            "type": "object",
            "properties": [
                "heading": ["type": "string"],
                "items": ["type": "array", "items": citedItem]
            ],
            "required": ["heading", "items"],
            "additionalProperties": false
        ]
        let action: [String: Any] = [
            "type": "object",
            "properties": [
                "task": ["type": "string"],
                "owner": ["type": "string"],
                "due_date": ["type": "string"],
                "segment_ids": ["type": "array", "items": ["type": "string"]]
            ],
            "required": ["task", "owner", "due_date", "segment_ids"],
            "additionalProperties": false
        ]
        return [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "overview": ["type": "string"],
                "sections": ["type": "array", "items": section],
                "decisions": ["type": "array", "items": citedItem],
                "action_items": ["type": "array", "items": action],
                "open_questions": ["type": "array", "items": citedItem]
            ],
            "required": ["title", "overview", "sections", "decisions", "action_items", "open_questions"],
            "additionalProperties": false
        ]
    }

    static var chatSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "answer": ["type": "string"],
                "segment_ids": ["type": "array", "items": ["type": "string"]]
            ],
            "required": ["answer", "segment_ids"],
            "additionalProperties": false
        ]
    }
}

struct MultipartFormFile {
    let boundary: String
    private let outputURL: URL
    private let handle: FileHandle

    init(boundary: String, outputURL: URL) throws {
        self.boundary = boundary
        self.outputURL = outputURL
        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.handle = try FileHandle(forWritingTo: outputURL)
    }

    func addField(name: String, value: String) throws {
        try append("--\(boundary)\r\n")
        try append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        try append("\(value)\r\n")
    }

    func addFile(name: String, filename: String, mimeType: String, fileURL: URL) throws {
        try append("--\(boundary)\r\n")
        try append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        try append("Content-Type: \(mimeType)\r\n\r\n")
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
        }
        try append("\r\n")
    }

    func finalize() throws {
        try append("--\(boundary)--\r\n")
        try handle.synchronize()
        try handle.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
    }

    private func append(_ string: String) throws {
        try handle.write(contentsOf: Data(string.utf8))
    }
}

private struct TranscriptionWireResponse: Decodable {
    struct Segment: Decodable {
        let speaker: String?
        let start: Double
        let end: Double
        let text: String
    }
    let language: String?
    let segments: [Segment]
    let usage: UsageWire?
}

private struct UsageWire: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let inputTokenDetails: InputDetails?

    struct InputDetails: Decodable {
        let cachedTokens: Int?
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
        case inputTokenDetails = "input_token_details"
    }

    var domain: TokenUsage {
        TokenUsage(
            inputTokens: inputTokens ?? max(0, (totalTokens ?? 0) - (outputTokens ?? 0)),
            outputTokens: outputTokens ?? 0,
            cachedInputTokens: inputTokenDetails?.cachedTokens ?? 0
        )
    }
}

private struct ResponsesWireEnvelope: Decodable {
    struct Output: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
            let refusal: String?
        }
        let type: String
        let content: [Content]?
    }
    let output: [Output]
    let usage: UsageWire?

    func outputText() throws -> String {
        for item in output {
            for content in item.content ?? [] {
                if content.type == "refusal", let refusal = content.refusal {
                    throw ProviderError.refused(refusal)
                }
                if content.type == "output_text", let text = content.text { return text }
            }
        }
        throw ProviderError.unsupportedResponse
    }
}

private struct AnalysisWire: Decodable {
    struct Item: Decodable {
        let text: String
        let segmentIDs: [String]
        enum CodingKeys: String, CodingKey { case text; case segmentIDs = "segment_ids" }
    }
    struct Section: Decodable {
        let heading: String
        let items: [Item]
    }
    struct Action: Decodable {
        let task: String
        let owner: String
        let dueDate: String
        let segmentIDs: [String]
        enum CodingKeys: String, CodingKey {
            case task, owner
            case dueDate = "due_date"
            case segmentIDs = "segment_ids"
        }
    }
    let title: String
    let overview: String
    let sections: [Section]
    let decisions: [Item]
    let actionItems: [Action]
    let openQuestions: [Item]

    enum CodingKeys: String, CodingKey {
        case title, overview, sections, decisions
        case actionItems = "action_items"
        case openQuestions = "open_questions"
    }

    func domain(using lookup: [String: TranscriptSegmentValue]) -> AnalysisDocument {
        func item(_ wire: Item) -> CitedText {
            CitedText(
                text: wire.text,
                citations: OpenAIProvider.resolveCitations(wire.segmentIDs, lookup: lookup)
            )
        }
        return AnalysisDocument(
            title: title,
            overview: overview,
            sections: sections.map { section in
                AnalysisSection(heading: section.heading, items: section.items.map(item))
            },
            decisions: decisions.map(item),
            actionItems: actionItems.map { action in
                ActionItem(
                    task: action.task,
                    owner: action.owner,
                    dueDate: action.dueDate,
                    citations: OpenAIProvider.resolveCitations(action.segmentIDs, lookup: lookup)
                )
            },
            openQuestions: openQuestions.map(item)
        )
    }
}

private struct ChatWire: Decodable {
    let answer: String
    let segmentIDs: [String]
    enum CodingKeys: String, CodingKey { case answer; case segmentIDs = "segment_ids" }
}

private struct OpenAIWireError: Decodable {
    struct Detail: Decodable { let message: String }
    let error: Detail
}
