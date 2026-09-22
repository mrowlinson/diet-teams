// CatchUp.swift — om-catchup lane: opt-in AI thread catch-up.
//
// IDEA-only inspiration from Teamsly (AGPL): a summarize / TL;DR /
// action-items entry point on long threads. No Teamsly code is used here.
//
// Contract:
//   - OFF by default; nothing leaves the machine until the user enables
//     it, enters their own key, and taps Summarize.
//   - BYO OpenAI-compatible key + configurable base URL + model.
//   - The privacy note (thread text leaves the machine) shows in both
//     Settings and the sheet, every time.
//   - Tests inject a mock transport (same seam style as PresenceStore's
//     fetchers); live traffic goes through URLSessionCatchUpTransport.
import Foundation

// MARK: - Pure helpers

public enum CatchUp {
    /// Threads this long (or longer) get the Catch-up entry point.
    public static let threshold = 20
    /// Max transcript chars sent to the model; overflow drops the head.
    public static let maxTranscriptChars = 12_000

    public static let privacyNote =
        "Catch-up sends this thread's text to your configured AI endpoint. It leaves this machine."

    public static func shouldOffer(messageCount: Int) -> Bool {
        messageCount >= threshold
    }

    /// "{base}/chat/completions" — exactly one join slash.
    public static func endpoint(baseURL: String) -> String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/chat/completions"
    }

    /// "Sender: one-line content" per message, oldest first, tail-capped
    /// at maxTranscriptChars on a line boundary when possible.
    public static func transcript(from messages: [ChatMessage]) -> String {
        let lines = messages.map { "\($0.sender): \(singleLine($0.content))" }
        var text = lines.joined(separator: "\n")
        if text.count > maxTranscriptChars {
            text = String(text.suffix(maxTranscriptChars))
            if let nl = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: nl)...])
            }
        }
        return text
    }

    /// TL;DR + key points + action items instruction over the transcript.
    public static func prompt(transcript: String) -> String {
        """
        Catch me up on this chat thread. Reply in exactly three sections:
        1. TL;DR — two sentences max.
        2. Key points — short bullets, oldest first.
        3. Action items — one bullet per item, with owner when named, else "Unassigned".

        Thread:
        \(transcript)
        """
    }

    /// OpenAI-compatible chat-completions body (pure, test seam).
    public static func requestBody(model: String, prompt: String) -> Data {
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    private static func singleLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Config

/// BYO credentials. `enabled` defaults false (OFF); key starts empty.
public struct CatchUpConfig: Sendable, Equatable {
    public var enabled: Bool
    public var baseURL: String
    public var model: String
    public var apiKey: String

    public init(
        enabled: Bool = false,
        baseURL: String = "https://api.openai.com/v1",
        model: String = "gpt-4o-mini",
        apiKey: String = ""
    ) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }
}

// MARK: - Errors

public enum CatchUpError: Error, Sendable, Equatable {
    case off
    case missingKey
    case badURL
    case empty
    case server(String)

    public var message: String {
        switch self {
        case .off: "Catch-up is off. Enable it in Settings first."
        case .missingKey: "No API key. Add your key in Settings first."
        case .badURL: "Bad base URL. Check it in Settings."
        case .empty: "The endpoint returned an empty summary."
        case let .server(detail): "Catch-up failed: \(detail)"
        }
    }
}

// MARK: - Transport

/// One OpenAI-compatible chat completion. The mock seam: tests and the
/// --show-catchup shot hook inject fakes; live uses URLSession.
public protocol CatchUpTransport: Sendable {
    func complete(baseURL: String, apiKey: String, model: String, prompt: String) async throws -> String
}

/// Live transport: POST {baseURL}/chat/completions, Bearer key.
public struct URLSessionCatchUpTransport: CatchUpTransport {
    public init() {}

    public func complete(baseURL: String, apiKey: String, model: String, prompt: String) async throws -> String {
        guard let url = URL(string: CatchUp.endpoint(baseURL: baseURL)) else {
            throw CatchUpError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = CatchUp.requestBody(model: model, prompt: prompt)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw CatchUpError.server("no response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw CatchUpError.server("HTTP \(http.statusCode)")
        }
        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw CatchUpError.empty
        }
        return text
    }
}

/// Minimal chat-completions response: choices[0].message.content.
public struct ChatCompletionsResponse: Decodable, Sendable {
    public struct Choice: Decodable, Sendable {
        public struct Message: Decodable, Sendable {
            public let content: String
        }

        public let message: Message
    }

    public let choices: [Choice]
}

/// Canned transport for tests, previews, and the --show-catchup shot
/// hook. Records every prompt it was given.
public final class CatchUpCannedTransport: CatchUpTransport, @unchecked Sendable {
    public private(set) var prompts: [String] = []
    public var stub: String
    public var failure: Error?

    public init(stub: String = "", failure: Error? = nil) {
        self.stub = stub
        self.failure = failure
    }

    public func complete(baseURL _: String, apiKey _: String, model _: String, prompt: String) async throws -> String {
        prompts.append(prompt)
        if let failure { throw failure }
        return stub
    }
}

// MARK: - Store

/// Catch-up state for the app. Config persists in UserDefaults (OFF
/// default); the summary state resets per tap.
@MainActor
public final class CatchUpStore: ObservableObject {
    public enum State: Equatable {
        case idle
        case loading
        case loaded(String)
        case failed(String)
    }

    enum Keys {
        static let enabled = "catchup.enabled"
        static let baseURL = "catchup.baseURL"
        static let model = "catchup.model"
        static let key = "catchup.apiKey"
    }

    @Published public var config: CatchUpConfig {
        didSet { save() }
    }

    @Published public private(set) var state: State = .idle

    private let transport: any CatchUpTransport
    private let defaults: UserDefaults

    /// Nonisolated so views can take a default `CatchUpStore()` in
    /// their (nonisolated) inits; all members stay main-actor-isolated.
    public nonisolated init(
        transport: (any CatchUpTransport)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.transport = transport ?? URLSessionCatchUpTransport()
        self.defaults = defaults
        var cfg = CatchUpConfig()
        if defaults.bool(forKey: Keys.enabled) { cfg.enabled = true }
        if let b = defaults.string(forKey: Keys.baseURL), !b.isEmpty { cfg.baseURL = b }
        if let m = defaults.string(forKey: Keys.model), !m.isEmpty { cfg.model = m }
        if let k = defaults.string(forKey: Keys.key) { cfg.apiKey = k }
        _config = Published(initialValue: cfg)
        _state = Published(initialValue: .idle)
    }

    /// Summarize the given messages. Disabled/empty-key/empty-thread all
    /// fail WITHOUT touching the transport (no traffic while OFF).
    public func summarize(messages: [ChatMessage]) async {
        guard config.enabled else { state = .failed(CatchUpError.off.message); return }
        guard !config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            state = .failed(CatchUpError.missingKey.message)
            return
        }
        let transcript = CatchUp.transcript(from: messages)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed("Nothing to summarize.")
            return
        }
        state = .loading
        do {
            let text = try await transport.complete(
                baseURL: config.baseURL, apiKey: config.apiKey,
                model: config.model, prompt: CatchUp.prompt(transcript: transcript))
            state = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .failed(CatchUpError.empty.message) : .loaded(text)
        } catch let e as CatchUpError {
            state = .failed(e.message)
        } catch {
            state = .failed(String(describing: error))
        }
    }

    /// Back to idle (sheet reopen, chat switch).
    public func reset() {
        state = .idle
    }

    /// Test/demo seam: adopt a config without touching persistence.
    public func adopt(_ cfg: CatchUpConfig) {
        config = cfg
    }

    private func save() {
        defaults.set(config.enabled, forKey: Keys.enabled)
        defaults.set(config.baseURL, forKey: Keys.baseURL)
        defaults.set(config.model, forKey: Keys.model)
        defaults.set(config.apiKey, forKey: Keys.key)
    }
}
