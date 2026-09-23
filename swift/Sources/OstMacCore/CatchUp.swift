// CatchUp.swift — om-catchup lane: opt-in AI thread catch-up.
//
// IDEA-only inspiration from Teamsly (AGPL): a summarize / TL;DR /
// action-items entry point on long threads. No Teamsly code is used here.
//
// Contract:
//   - OFF by default; nothing leaves the machine until the user enables
//     it and taps Summarize.
//   - Provider picker (OpenCode CLI | OpenAI-compatible | OpenCode) +
//     configurable base URL + model. OpenCode CLI is the default and
//     is CLI-ONLY: it always shells out to `opencode run` (CLI auth
//     covers the free-tier Spark model) and never attempts HTTPS,
//     even when a key is configured. Direct providers use HTTPS only
//     and still require a key.
//   - The key lives in the macOS keychain (service
//     "dev.ostmac.OstMac.catchup", account "catchup-api-key"), never
//     in UserDefaults/plist. The Settings key field writes keychain.
//     The key is only used by the direct-HTTPS path.
//   - The privacy note (thread text leaves the machine) shows in both
//     Settings and the sheet, every time.
//   - Tests inject a mock transport (same seam style as PresenceStore's
//     fetchers) + a memory key store; live direct traffic goes through
//     URLSessionCatchUpTransport, live CLI traffic through
//     OpenCodeCLICatchUpTransport + an injected CatchUpCLIRunner.
//   - Every failure surfaces in the UI as .failed(detail); nothing
//     fails silently.
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
    case openCodeCLI = "opencode-cli"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openAICompatible: "OpenAI-compatible"
        case .openCode: "OpenCode"
        case .openCodeCLI: "OpenCode CLI"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAICompatible: "https://api.openai.com/v1"
        case .openCode: "https://opencode.ai/zen/v1"
        case .openCodeCLI: "https://opencode.ai/zen/v1"
        }
    }

    public var defaultModel: String {
        switch self {
        case .openAICompatible: "gpt-4o-mini"
        case .openCode: "muse-spark-1.3-contributor-free"
        case .openCodeCLI: "muse-spark-1.3-contributor-free"
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
        provider: CatchUpProvider = .openCodeCLI,
        enabled: Bool = false,
        baseURL: String = "https://opencode.ai/zen/v1",
        model: String = "muse-spark-1.3-contributor-free",
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
    case forbidden
    case cliMissing
    case cliAuthExpired
    case cliTimeout
    case cliBadOutput

    /// Pure HTTP-status mapping (test seam): 403 gets its own clean
    /// message; every other non-2xx stays a generic server failure.
    public static func http(_ statusCode: Int) -> CatchUpError {
        statusCode == 403 ? .forbidden : .server("HTTP \(statusCode)")
    }

    public var message: String {
        switch self {
        case .off: "Catch-up is off. Enable it in Settings first."
        case .missingKey: "No API key. Add your key in Settings first."
        case .badURL: "Bad base URL. Check it in Settings."
        case .empty: "The endpoint returned an empty summary."
        case let .server(detail): "Catch-up failed: \(detail)"
        case .forbidden: "The endpoint refused the request (HTTP 403). Check your API key and model access, then retry."
        case .cliMissing: "opencode CLI not found. Install it from opencode.ai, run `opencode auth login`, then retry."
        case .cliAuthExpired: "OpenCode CLI login expired. Run `opencode auth login` and retry."
        case .cliTimeout: "OpenCode CLI timed out. Retry."
        case .cliBadOutput: "OpenCode CLI returned unreadable output. Retry."
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
            throw CatchUpError.http(http.statusCode)
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

// MARK: - OpenCode CLI path

/// Pure CLI helpers: argv shape, auth-failure sniffing, JSON output
/// parsing. `opencode run --format json` emits JSON (one object per
/// line for streaming events); the summary is the last assistant
/// message payload we can find.
public enum CatchUpCLI {
    public static let executable = "opencode"
    public static let defaultTimeoutSeconds: Double = 60
    /// Install guide surface (sheet + Settings when the CLI is
    /// missing). Install via `installCommand`, then `loginCommand`.
    public static let installSite = "https://opencode.ai"
    public static let installCommand = "curl -fsSL https://opencode.ai/install | bash"
    public static let loginCommand = "opencode auth login"

    public static func arguments(model: String, prompt: String) -> [String] {
        ["run", "--format", "json", "--model", model, prompt]
    }

    /// True when a nonzero-exit blob looks like expired/missing CLI
    /// auth rather than a generic failure. Only called on failure
    /// output, never on a successful summary.
    public static func isAuthFailure(stderr: String, stdout: String) -> Bool {
        let blob = (stderr + "\n" + stdout).lowercased()
        return blob.contains("unauthorized")
            || blob.contains("unauthenticated")
            || blob.contains("auth")
            || blob.contains("login")
            || blob.contains("expired")
            || blob.contains("invalid key")
            || blob.contains("invalid api key")
            || blob.contains("forbidden")
            || blob.contains(" 401")
            || blob.contains(" 403")
    }

    /// Extract the summary text from `opencode run --format json`
    /// stdout. Accepts a single JSON object or JSON lines; picks the
    /// last non-empty assistant payload. Throws .cliBadOutput when
    /// nothing parses or nothing usable is found.
    public static func parseOutput(_ stdout: String) throws -> String {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CatchUpError.cliBadOutput }
        var candidates: [String] = []
        // Whole-blob first (single JSON object), then line by line
        // (streaming JSONL events).
        var blobs = [trimmed]
        blobs.append(contentsOf: trimmed.components(separatedBy: "\n"))
        for blob in blobs {
            let line = blob.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("{"), let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data)
            else { continue }
            if let found = extractText(from: json), !found.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                candidates.append(found)
            }
        }
        guard let last = candidates.last else { throw CatchUpError.cliBadOutput }
        return last
    }

    private static func extractText(from json: Any) -> String? {
        guard let obj = json as? [String: Any] else { return nil }
        // Streaming event: {"type":"message","role":"assistant","content":...}
        if let type = obj["type"] as? String, type == "message" {
            if let role = obj["role"] as? String, role != "assistant" { return nil }
            return stringOrBlockText(obj["content"])
        }
        // Direct payload keys.
        for key in ["content", "text", "result", "output", "summary"] {
            if let s = stringOrBlockText(obj[key]), !s.isEmpty { return s }
        }
        // OpenAI-compatible shape.
        if let choices = obj["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let s = stringOrBlockText(message["content"]), !s.isEmpty
        {
            return s
        }
        // Message list: last assistant wins.
        if let messages = obj["messages"] as? [[String: Any]] {
            for message in messages.reversed() {
                let role = message["role"] as? String
                if role == nil || role == "assistant",
                   let s = stringOrBlockText(message["content"]), !s.isEmpty
                {
                    return s
                }
            }
        }
        return nil
    }

    private static func stringOrBlockText(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let blocks = value as? [[String: Any]] {
            let parts = blocks.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
        return nil
    }
}

/// Captured CLI run: stdout + stderr + exit code.
public struct CatchUpCLIResult: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// Shell-out seam. Live = Process; tests inject
/// `CatchUpMockCLIRunner` and never spawn.
public protocol CatchUpCLIRunner: Sendable {
    /// False when the `opencode` executable cannot be found (drives
    /// the missing-CLI install prompt; the run path still throws
    /// .cliMissing if the binary vanishes between check and run).
    var isAvailable: Bool { get }
    func run(model: String, prompt: String, timeoutSeconds: Double) async throws -> CatchUpCLIResult
}

/// Live runner: resolves `opencode` on PATH (+ brew locations GUI
/// apps miss), runs `opencode run --format json --model <m> <prompt>`
/// with a timeout, captures stdout/stderr.
public struct ProcessCatchUpCLIRunner: CatchUpCLIRunner {
    public init() {}

    public var isAvailable: Bool { Self.resolveExecutable() != nil }

    public func run(model: String, prompt: String, timeoutSeconds: Double) async throws -> CatchUpCLIResult {
        guard let executableURL = Self.resolveExecutable() else {
            throw CatchUpError.cliMissing
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = CatchUpCLI.arguments(model: model, prompt: prompt)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw CatchUpError.cliMissing
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                // Brief grace, then force.
                try? await Task.sleep(nanoseconds: 200_000_000)
                if process.isRunning { process.interrupt() }
                throw CatchUpError.cliTimeout
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return CatchUpCLIResult(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus)
    }

    static func resolveExecutable() -> URL? {
        let fm = FileManager.default
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .components(separatedBy: ":").filter { !$0.isEmpty }
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] where !dirs.contains(extra) {
            dirs.append(extra)
        }
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(CatchUpCLI.executable)
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}

/// Mock CLI runner for tests. Records every (model, prompt) call;
/// returns `result` or throws `failure`.
public final class CatchUpMockCLIRunner: CatchUpCLIRunner, @unchecked Sendable {
    public private(set) var calls: [(model: String, prompt: String)] = []
    public var result: CatchUpCLIResult?
    public var failure: Error?
    public var isAvailable: Bool

    public init(result: CatchUpCLIResult? = nil, failure: Error? = nil, isAvailable: Bool = true) {
        self.result = result
        self.failure = failure
        self.isAvailable = isAvailable
    }

    public func run(model: String, prompt: String, timeoutSeconds _: Double) async throws -> CatchUpCLIResult {
        calls.append((model: model, prompt: prompt))
        if let failure { throw failure }
        return result ?? CatchUpCLIResult(stdout: "", stderr: "", exitCode: 0)
    }
}

/// CLI transport: shells out via the injected runner, maps the four
/// CLI modes (missing / auth-expiry / timeout / bad output) to
/// CatchUpError, surfaces everything — never silent.
public struct OpenCodeCLICatchUpTransport: CatchUpTransport {
    public let runner: any CatchUpCLIRunner
    public let timeoutSeconds: Double

    public init(
        runner: (any CatchUpCLIRunner)? = nil,
        timeoutSeconds: Double = CatchUpCLI.defaultTimeoutSeconds
    ) {
        self.runner = runner ?? ProcessCatchUpCLIRunner()
        self.timeoutSeconds = timeoutSeconds
    }

    /// CLI presence check for the install prompt (see
    /// `CatchUpStore.cliAvailable`).
    public var isAvailable: Bool { runner.isAvailable }

    public func complete(baseURL _: String, apiKey _: String, model: String, prompt: String) async throws -> String {
        let res: CatchUpCLIResult
        do {
            res = try await runner.run(model: model, prompt: prompt, timeoutSeconds: timeoutSeconds)
        } catch let e as CatchUpError {
            throw e
        } catch {
            throw CatchUpError.server(String(describing: error))
        }
        if res.exitCode != 0 {
            if CatchUpCLI.isAuthFailure(stderr: res.stderr, stdout: res.stdout) {
                throw CatchUpError.cliAuthExpired
            }
            if res.exitCode == 127
                && (res.stderr + res.stdout).lowercased().contains(CatchUpCLI.executable)
            {
                throw CatchUpError.cliMissing
            }
            let detail = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CatchUpError.server("opencode CLI failed: \(detail.isEmpty ? "exit \(res.exitCode)" : String(detail.prefix(300)))")
        }
        let text = try CatchUpCLI.parseOutput(res.stdout)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CatchUpError.empty
        }
        return text
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

    /// Structured form of the current `.failed` detail (nil unless the
    /// last summarize ended in a known `CatchUpError`). The sheet uses
    /// it to show the CLI install prompt for `.cliMissing`.
    @Published public private(set) var lastError: CatchUpError?

    /// Whether the `opencode` binary resolves on PATH (via the CLI
    /// runner). Non-CLI transports assume true; refresh explicitly
    /// with `refreshCLIStatus()` (e.g. after the user installs it).
    @Published public private(set) var cliAvailable: Bool

    private let transport: any CatchUpTransport
    private let cliTransport: any CatchUpTransport
    private let defaults: UserDefaults
    private let keys: any CatchUpKeyStore

    /// Nonisolated so views can take a default `CatchUpStore()` in
    /// their (nonisolated) inits; all members stay main-actor-isolated.
    public nonisolated init(
        transport: (any CatchUpTransport)? = nil,
        cliTransport: (any CatchUpTransport)? = nil,
        defaults: UserDefaults = .standard,
        keyStore: (any CatchUpKeyStore)? = nil
    ) {
        self.transport = transport ?? URLSessionCatchUpTransport()
        let cli = cliTransport ?? OpenCodeCLICatchUpTransport()
        self.cliTransport = cli
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
        _lastError = Published(initialValue: nil)
        _cliAvailable = Published(initialValue: (cli as? OpenCodeCLICatchUpTransport)?.isAvailable ?? true)
    }

    /// Summarize the given messages. Disabled/empty-thread always fail
    /// WITHOUT touching either transport. Provider select is
    /// exclusive: the CLI provider (default) ALWAYS shells out and
    /// never attempts HTTPS, even with a key configured; direct
    /// providers ALWAYS use HTTPS and require a key, failing with
    /// missingKey WITHOUT touching the transport. Every failure lands
    /// in `.failed` with a Retry path — never stuck in `.loading`.
    public func summarize(messages: [ChatMessage]) async {
        guard config.enabled else {
            lastError = .off
            state = .failed(CatchUpError.off.message)
            return
        }
        let hasKey = !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if config.provider != .openCodeCLI, !hasKey {
            lastError = .missingKey
            state = .failed(CatchUpError.missingKey.message)
            return
        }
        let transcript = CatchUp.transcript(from: messages)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = nil
            state = .failed("Nothing to summarize.")
            return
        }
        state = .loading
        do {
            // Exclusive routing: CLI-selected => CLI ONLY.
            let active: any CatchUpTransport = config.provider == .openCodeCLI ? cliTransport : transport
            let text = try await active.complete(
                baseURL: config.baseURL, apiKey: config.apiKey,
                model: config.model, prompt: CatchUp.prompt(transcript: transcript))
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lastError = .empty
                state = .failed(CatchUpError.empty.message)
            } else {
                lastError = nil
                state = .loaded(text)
            }
        } catch let e as CatchUpError {
            lastError = e
            state = .failed(e.message)
        } catch {
            lastError = nil
            state = .failed(String(describing: error))
        }
    }

    /// Back to idle (sheet reopen, chat switch).
    public func reset() {
        state = .idle
        lastError = nil
    }

    /// Re-check whether the `opencode` binary resolves (Settings
    /// "Check again" after the user installs it).
    public func refreshCLIStatus() {
        cliAvailable = (cliTransport as? OpenCodeCLICatchUpTransport)?.isAvailable ?? true
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
