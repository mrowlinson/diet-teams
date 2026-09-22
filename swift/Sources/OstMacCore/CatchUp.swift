// CatchUp.swift — om-catchup lane: opt-in AI thread catch-up.
//
// IDEA-only inspiration from Teamsly (AGPL): a summarize / TL;DR /
// action-items entry point on long threads. No Teamsly code is used here.
//
// Contract:
//   - OFF by default; nothing leaves the machine until the user enables
//     it, enters their own key, and taps Summarize.
//   - BYO key + provider picker (OpenAI-compatible | OpenCode) +
//     configurable base URL + model.
//   - The key lives in the macOS keychain (service
//     "dev.ostmac.OstMac.catchup", account "catchup-api-key"), never
//     in UserDefaults/plist. The Settings key field writes keychain.
//   - The privacy note (thread text leaves the machine) shows in both
//     Settings and the sheet, every time.
//   - Tests inject a mock transport (same seam style as PresenceStore's
//     fetchers) + a memory key store; live traffic goes through
//     URLSessionCatchUpTransport.
//
// OpenCode discovery (opencode.ai, 2026-09-22):
//   - Config file: opencode.json — {"$schema":
//     "https://opencode.ai/config.json", "provider": {<id>: {"npm":
//     "@ai-sdk/openai-compatible", "name": ..., "options":
//     {"baseURL": ...}, "models": {<model-id>: {...}}}}}
//   - Hosted API (OpenCode Zen): base https://opencode.ai/zen/v1,
//     OpenAI-compatible; POST {base}/chat/completions, auth
//     `Authorization: Bearer <key>` (key from https://opencode.ai/auth,
//     env OPENCODE_API_KEY). Model-id format on Zen: bare ids
//     ("provider/model" only in opencode.json references).
//   - 'Meta Muse Spark 1.3 Free' candidates: Zen
//     "muse-spark-1.3-contributor-free" ($0, models.dev opencode page,
//     exact name match) > Zen "muse-spark-1.3" (paid $1.25/$4.25) >
//     OpenRouter "meta/muse-spark-1.3:free" (wrong provider for the
//     Zen base URL) > "muse-spark-1.2-contributor-free" (free, older).
//     Preloaded id: muse-spark-1.3-contributor-free.
import Foundation
import Security

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

/// AI endpoint provider. Switching preloads that provider's base URL
/// + model (see `CatchUpStore.selectProvider`).
public enum CatchUpProvider: String, Sendable, Equatable, CaseIterable, Identifiable {
    case openAICompatible = "openai-compatible"
    case openCode = "opencode"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openAICompatible: "OpenAI-compatible"
        case .openCode: "OpenCode"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAICompatible: "https://api.openai.com/v1"
        case .openCode: "https://opencode.ai/zen/v1"
        }
    }

    public var defaultModel: String {
        switch self {
        case .openAICompatible: "gpt-4o-mini"
        case .openCode: "muse-spark-1.3-contributor-free"
        }
    }
}

/// BYO credentials. `enabled` defaults false (OFF); key starts empty.
/// The key is in-memory only here — persisted in the keychain, never
/// in UserDefaults (see `CatchUpStore.save`).
public struct CatchUpConfig: Sendable, Equatable {
    public var provider: CatchUpProvider
    public var enabled: Bool
    public var baseURL: String
    public var model: String
    public var apiKey: String

    public init(
        provider: CatchUpProvider = .openAICompatible,
        enabled: Bool = false,
        baseURL: String = "https://api.openai.com/v1",
        model: String = "gpt-4o-mini",
        apiKey: String = ""
    ) {
        self.provider = provider
        self.enabled = enabled
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    /// Preset config for a provider: its base URL + model, key untouched.
    public func withProvider(_ provider: CatchUpProvider) -> CatchUpConfig {
        var out = self
        out.provider = provider
        out.baseURL = provider.defaultBaseURL
        out.model = provider.defaultModel
        return out
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

// MARK: - Key storage

/// API-key persistence seam. Live = macOS keychain; tests and the
/// --show-catchup shot hook inject `CatchUpMemoryKeyStore` so they
/// never touch the real keychain.
public protocol CatchUpKeyStore: Sendable {
    func load() -> String?
    func save(_ key: String)
    func clear()
}

/// macOS keychain item: service "dev.ostmac.OstMac.catchup", account
/// "catchup-api-key". Preload from a shell (key via $KEY only):
///   security add-generic-password -a catchup-api-key \
///     -s dev.ostmac.OstMac.catchup -w "$KEY" -U
public struct CatchUpSystemKeychain: CatchUpKeyStore {
    public static let service = "dev.ostmac.OstMac.catchup"
    public static let account = "catchup-api-key"

    public init() {}

    public func load() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    public func save(_ key: String) {
        guard !key.isEmpty else { clear(); return }
        let data = Data(key.utf8)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        if SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess {
            _ = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = q
            add[kSecValueData as String] = data
            _ = SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func clear() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        _ = SecItemDelete(q as CFDictionary)
    }
}

/// In-memory key store for tests, previews, and the shot hook.
public final class CatchUpMemoryKeyStore: CatchUpKeyStore, @unchecked Sendable {
    private var key: String?

    public init(key: String? = nil) {
        self.key = key
    }

    public func load() -> String? { key }
    public func save(_ key: String) { self.key = key.isEmpty ? nil : key }
    public func clear() { key = nil }
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

/// Catch-up state for the app. Non-secret config persists in
/// UserDefaults (OFF default); the key lives in the key store (live:
/// macOS keychain) and is only ever in memory on `config`. The
/// summary state resets per tap.
@MainActor
public final class CatchUpStore: ObservableObject {
    public enum State: Equatable {
        case idle
        case loading
        case loaded(String)
        case failed(String)
    }

    enum Keys {
        static let provider = "catchup.provider"
        static let enabled = "catchup.enabled"
        static let baseURL = "catchup.baseURL"
        static let model = "catchup.model"
        /// Legacy: the pre-keychain lane kept the key here. Read once
        /// for migration, never written.
        static let legacyKey = "catchup.apiKey"
    }

    @Published public var config: CatchUpConfig {
        didSet { save() }
    }

    @Published public private(set) var state: State = .idle

    private let transport: any CatchUpTransport
    private let defaults: UserDefaults
    private let keys: any CatchUpKeyStore

    /// Nonisolated so views can take a default `CatchUpStore()` in
    /// their (nonisolated) inits; all members stay main-actor-isolated.
    public nonisolated init(
        transport: (any CatchUpTransport)? = nil,
        defaults: UserDefaults = .standard,
        keyStore: (any CatchUpKeyStore)? = nil
    ) {
        self.transport = transport ?? URLSessionCatchUpTransport()
        self.defaults = defaults
        let keys = keyStore ?? CatchUpSystemKeychain()
        self.keys = keys
        var cfg = CatchUpConfig()
        if let p = defaults.string(forKey: Keys.provider),
           let provider = CatchUpProvider(rawValue: p)
        {
            cfg.provider = provider
        }
        if defaults.bool(forKey: Keys.enabled) { cfg.enabled = true }
        if let b = defaults.string(forKey: Keys.baseURL), !b.isEmpty { cfg.baseURL = b }
        if let m = defaults.string(forKey: Keys.model), !m.isEmpty { cfg.model = m }
        if let k = keys.load(), !k.isEmpty {
            cfg.apiKey = k
        } else if let legacy = defaults.string(forKey: Keys.legacyKey), !legacy.isEmpty {
            // One-time migration: move the pre-keychain key into the
            // key store, scrub it from defaults.
            cfg.apiKey = legacy
            keys.save(legacy)
            defaults.removeObject(forKey: Keys.legacyKey)
        }
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

    /// Provider switch from the Settings picker: preloads the
    /// provider's base URL + model, keeps the key + enabled flag.
    public func selectProvider(_ provider: CatchUpProvider) {
        config = config.withProvider(provider)
    }

    private func save() {
        defaults.set(config.provider.rawValue, forKey: Keys.provider)
        defaults.set(config.enabled, forKey: Keys.enabled)
        defaults.set(config.baseURL, forKey: Keys.baseURL)
        defaults.set(config.model, forKey: Keys.model)
        // Key → key store only. Never UserDefaults (see migration in
        // init for the one pre-keychain exception we scrub).
        keys.save(config.apiKey)
    }
}
