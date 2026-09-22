// Models.swift — pure Codable for ostmac-core JSON envelopes. No C calls.
import Foundation

/// Generic error envelope: {"ok":false,"error":code,"detail":...}
public struct CoreError: Decodable, Sendable {
    public let error: String
    public let detail: String?

    public var message: String {
        detail.map { "\(error): \($0)" } ?? error
    }
}

public struct TokenSlot: Decodable, Sendable {
    public let present: Bool
    public let expired: Bool
}

public struct TokenSummary: Decodable, Sendable {
    public let aad: TokenSlot
    public let refresh_present: Bool
    public let graph: TokenSlot
    public let ic3: TokenSlot
    public let recorder: TokenSlot
    public let skype: TokenSlot
    public let region_gtms_present: Bool
}

public struct StatusResponse: Decodable, Sendable {
    public let ok: Bool
    public let signed_in: Bool
    public let tokens: TokenSummary
}

public struct DeviceStart: Decodable, Sendable {
    public let ok: Bool
    public let session: String
    public let verification_uri: String
    public let user_code: String
    public let message: String
    public let expires_in: Int
    public let interval: Int
}

public struct DevicePoll: Decodable, Sendable {
    public let ok: Bool
    public let status: String
    public let interval: Int?
    public let tokens: TokenSummary?
}

// MARK: - Auth refresh / sign-out (om-authux lane)

/// Refresh envelope: `refreshed=false` means no refresh token is stored
/// (run the device-code flow); `tokens` is present only when refreshed.
public struct RefreshResponse: Decodable, Sendable {
    public let ok: Bool
    public let refreshed: Bool
    public let tokens: TokenSummary?
}

/// `{ok:true}` after tokens are cleared.
public struct SignOutResponse: Decodable, Sendable {
    public let ok: Bool
}

// MARK: - Identity (om-identity-own lane)

/// Current user from core `ostmac_whoami` (Graph /me, core-cached).
/// `display_name` is the `ChatMessage.sender` match key for `isOwn`
/// (same sender==name rule the ost TUI uses).
public struct WhoamiResponse: Decodable, Sendable {
    public let ok: Bool
    public let id: String
    public let display_name: String
    public let mail: String?
}

public struct ChatItem: Decodable, Sendable, Identifiable {
    public var id: String { chatId }
    public let chatId: String
    public let name: String
    public let is_group: Bool
    public let last_message_time: String?
    public let last_message_sender: String?
    public let last_message_preview: String?

    enum CodingKeys: String, CodingKey {
        case chatId = "id"
        case name, is_group, last_message_time
        case last_message_sender, last_message_preview
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(
        chatId: String, name: String, is_group: Bool = false,
        last_message_time: String? = nil,
        last_message_sender: String? = nil,
        last_message_preview: String? = nil
    ) {
        self.chatId = chatId
        self.name = name
        self.is_group = is_group
        self.last_message_time = last_message_time
        self.last_message_sender = last_message_sender
        self.last_message_preview = last_message_preview
    }
}

public struct ChatsResponse: Decodable, Sendable {
    public let ok: Bool
    public let chats: [ChatItem]

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(ok: Bool, chats: [ChatItem]) {
        self.ok = ok
        self.chats = chats
    }
}

// MARK: - Teams (om-teams lane)

/// One channel inside a team. Wire format from core `ostmac_teams`:
/// `{"id","name"}`. The id opens as a conversation through the same
/// messages/send path as chat ids (ost TUI parity).
public struct TeamChannel: Decodable, Sendable, Identifiable {
    public var id: String { channelId }
    public let channelId: String
    public let name: String

    enum CodingKeys: String, CodingKey {
        case channelId = "id"
        case name
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(channelId: String, name: String) {
        self.channelId = channelId
        self.name = name
    }
}

/// One joined team with its channels.
public struct TeamItem: Decodable, Sendable, Identifiable {
    public var id: String { teamId }
    public let teamId: String
    public let name: String
    public let channels: [TeamChannel]

    enum CodingKeys: String, CodingKey {
        case teamId = "id"
        case name, channels
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(teamId: String, name: String, channels: [TeamChannel]) {
        self.teamId = teamId
        self.name = name
        self.channels = channels
    }
}

public struct TeamsResponse: Decodable, Sendable {
    public let ok: Bool
    public let teams: [TeamItem]

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(ok: Bool, teams: [TeamItem]) {
        self.ok = ok
        self.teams = teams
    }
}

public struct TrouterPoll: Decodable, Sendable {
    public let ok: Bool
    public let events: [AnyJSON]
}

// MARK: - Conversation (om-conv lane)

/// One chat message. Wire format from core `ostmac_messages`:
/// `{"id","sender","timestamp","content"}`.
/// `isOwn` is host-side only (core never sends it; defaults false) and
/// drives bubble alignment. The realtime lane feeds this same model into
/// `ConversationStore.ingest(_:)`; matching `id` => in-place edit update.
public struct ChatMessage: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let sender: String
    public let timestamp: String
    public var content: String
    public var isOwn: Bool
    /// Unstripped server HTML (om-convrich): mention/code mining source.
    /// Absent on old payloads, realtime ingests, and local echoes.
    public var raw: String?
    /// Host-side: set when a realtime edit rewrites `content`.
    public var edited: Bool

    enum CodingKeys: String, CodingKey {
        case id, sender, timestamp, content, raw
    }

    public init(
        id: String, sender: String, timestamp: String,
        content: String, isOwn: Bool = false,
        raw: String? = nil, edited: Bool = false
    ) {
        self.id = id
        self.sender = sender
        self.timestamp = timestamp
        self.content = content
        self.isOwn = isOwn
        self.raw = raw
        self.edited = edited
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sender = try c.decode(String.self, forKey: .sender)
        timestamp = try c.decode(String.self, forKey: .timestamp)
        content = try c.decode(String.self, forKey: .content)
        raw = try c.decodeIfPresent(String.self, forKey: .raw)
        isOwn = false
        edited = false
    }

    /// "2026-09-22T12:53:06.9690000Z" -> "12:53" (today) or "12:53 22 Sep".
    /// Falls back to the raw prefix when the timestamp is missing/odd.
    public var displayTime: String {
        Self.shortTime(timestamp)
    }

    public static func shortTime(_ iso: String) -> String {
        let trimmed = iso.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 16 else {
            return trimmed.isEmpty ? "?" : trimmed
        }
        // Fast path: fixed-offset slice, no Date parsing on the hot path.
        // "2026-09-22T12:53:06..." -> date "2026-09-22", clock "12:53".
        let datePart = String(trimmed.prefix(10))
        let clockPart: String = {
            let idx = trimmed.index(trimmed.startIndex, offsetBy: 11)
            let end = trimmed.index(idx, offsetBy: 5, limitedBy: trimmed.endIndex)
            return end.map { String(trimmed[idx ..< $0]) } ?? String(trimmed.dropFirst(11).prefix(5))
        }()
        let today: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone.current
            return f.string(from: Date())
        }()
        if datePart == today { return clockPart }
        let monthDay: String = {
            let parts = datePart.split(separator: "-")
            guard parts.count == 3 else { return datePart }
            let months = [
                "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
            ]
            let m = Int(parts[1]).flatMap { (1 ... 12).contains($0) ? months[$0 - 1] : nil } ?? String(parts[1])
            return "\(Int(parts[2]) ?? 0) \(m)"
        }()
        return "\(clockPart) \(monthDay)"
    }
}

public struct MessagesResponse: Decodable, Sendable {
    public let ok: Bool
    public let chat_id: String?
    public let messages: [ChatMessage]
    /// Opaque cursor for the next older page; nil when history is exhausted.
    /// Absent (nil) on old core builds — treat as end of history.
    public let page_token: String?
}

public struct SendResponse: Decodable, Sendable {
    public let ok: Bool
    public let chat_id: String?
}

// MARK: - Presence (om-presence lane)

/// Own presence from core `ostmac_presence` / `ostmac_presence_set`
/// (Graph /me/presence): availability ∈ Available, Busy, DoNotDisturb,
/// Away, Offline, PresenceUnknown (+ future server values, passed through).
public struct PresenceResponse: Decodable, Sendable {
    public let ok: Bool
    public let availability: String
    public let activity: String

    /// Host-side construction (demo data, previews, mock fetchers).
    public init(ok: Bool, availability: String, activity: String) {
        self.ok = ok
        self.availability = availability
        self.activity = activity
    }
}

/// One other user's presence from core `ostmac_presence_user`
/// (Graph /users/{id}/presence). Same shape as own, plus the echoed id.
public struct UserPresenceResponse: Decodable, Sendable {
    public let ok: Bool
    public let id: String
    public let availability: String
    public let activity: String

    /// Host-side construction (demo data, previews, mock fetchers).
    public init(ok: Bool, id: String, availability: String, activity: String) {
        self.ok = ok
        self.id = id
        self.availability = availability
        self.activity = activity
    }
}

// MARK: - MRI resolution (om-steal-ids lane)

/// Graph user behind a Teams MRI, from core `ostmac_resolve_mri`
/// (Graph /users/{aad-oid}). `email` is nil for guests (no mail).
public struct ResolveMriResponse: Decodable, Sendable {
    public let ok: Bool
    public let id: String
    public let email: String?
    public let display_name: String

    /// Host-side construction (mock fetchers, caches).
    public init(ok: Bool, id: String, email: String?, display_name: String) {
        self.ok = ok
        self.id = id
        self.email = email
        self.display_name = display_name
    }
}

// MARK: - Token health (om-steal-ids lane)

/// One timed probe in a health report (port of teams-access
/// `HealthProbeResult`: name/ok/status/detail/durationMs).
public struct HealthProbe: Sendable, Equatable {
    public let name: String
    public let ok: Bool
    public let status: Int?
    public let detail: String
    public let durationMs: Int

    public init(name: String, ok: Bool, status: Int? = nil, detail: String, durationMs: Int) {
        self.name = name
        self.ok = ok
        self.status = status
        self.detail = detail
        self.durationMs = durationMs
    }
}

/// Overall health verdict (teams-access `overall`, verbatim).
public enum HealthOverall: String, Sendable {
    case ok, degraded, broken
}

/// One audience token slot in a health report (offline, from status).
public struct HealthToken: Sendable, Equatable {
    public let audience: String
    public let present: Bool
    public let expired: Bool

    public init(audience: String, present: Bool, expired: Bool) {
        self.audience = audience
        self.present = present
        self.expired = expired
    }

    public var state: String {
        !present ? "missing" : expired ? "expired" : "fresh"
    }
}

/// Full diagnostics report: offline per-audience token slots + live
/// probe results + verdict. Built host-side (no core envelope).
public struct HealthReport: Sendable {
    public let overall: HealthOverall
    public let tokens: [HealthToken]
    public let probes: [HealthProbe]
    public let accountUPN: String?

    public init(overall: HealthOverall, tokens: [HealthToken], probes: [HealthProbe], accountUPN: String? = nil) {
        self.overall = overall
        self.tokens = tokens
        self.probes = probes
        self.accountUPN = accountUPN
    }
}

// MARK: - Calls (om-signal lane: signaling only, no audio/video)

/// One call record from core `ostmac_call_*`. `state` is
/// placing|ringing|connected|ended|failed; `dir` is in|out.
public struct CallInfo: Decodable, Sendable, Equatable {
    public let id: String
    public let dir: String
    public let peer: String
    public let peerName: String
    public let thread: String
    public let state: String
    public let controller: String?
    public let startedAt: UInt64
    public let detail: String?

    enum CodingKeys: String, CodingKey {
        case id, dir, peer, thread, state, controller, detail
        case peerName = "peer_name"
        case startedAt = "started_at"
    }

    public var isActive: Bool {
        state == "placing" || state == "ringing" || state == "connected"
    }

    public var displayPeer: String {
        peerName.isEmpty ? (peer.isEmpty ? thread : peer) : peerName
    }

    public init(
        id: String, dir: String, peer: String, peerName: String = "",
        thread: String = "", state: String, controller: String? = nil,
        startedAt: UInt64 = 0, detail: String? = nil
    ) {
        self.id = id
        self.dir = dir
        self.peer = peer
        self.peerName = peerName
        self.thread = thread
        self.state = state
        self.controller = controller
        self.startedAt = startedAt
        self.detail = detail
    }
}

/// `{ok, call?}` from `ostmac_call_status`.
public struct CallStatus: Decodable, Sendable {
    public let ok: Bool
    public let call: CallInfo?
}

/// Place/accept/end envelope. Only the keys the action sets are read;
/// the rest stay nil (one shape for all call actions).
public struct CallResult: Decodable, Sendable {
    public let ok: Bool
    public let placed: Bool?
    public let accepted: Bool?
    public let ended: Bool?
    public let injected: Bool?
    public let mediaAnswered: Bool?
    public let rejection: String?
    public let responseBytes: Int?
    public let call: CallInfo?

    enum CodingKeys: String, CodingKey {
        case ok, placed, accepted, ended, injected, rejection, call
        case mediaAnswered = "media_answered"
        case responseBytes = "response_bytes"
    }
}

/// One typed call event from the feed (`calls[]` in the typed poll).
/// `kind` is incoming|end|rejected.
public struct CallEvent: Decodable, Sendable, Equatable {
    public let kind: String
    public let callID: String
    public let peer: String
    public let peerName: String
    public let detail: String?

    enum CodingKeys: String, CodingKey {
        case kind, peer, detail
        case callID = "call_id"
        case peerName = "peer_name"
    }

    public init(kind: String, callID: String, peer: String = "", peerName: String = "", detail: String? = nil) {
        self.kind = kind
        self.callID = callID
        self.peer = peer
        self.peerName = peerName
        self.detail = detail
    }
}

/// Minimal Any-Decodable for opaque Trouter event payloads.
public struct AnyJSON: Decodable, Sendable {
    public let value: String
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s; return }
        if let n = try? c.decode(Int.self) { value = String(n); return }
        if let b = try? c.decode(Bool.self) { value = String(b); return }
        if let a = try? c.decode([AnyJSON].self) {
            value = "[" + a.map(\.value).joined(separator: ",") + "]"; return
        }
        if let o = try? c.decode([String: AnyJSON].self) {
            value = "{" + o.map { "\($0):\($1.value)" }.joined(separator: ",") + "}"
            return
        }
        if c.decodeNil() { value = "null"; return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "unsupported JSON")
    }
}

/// Decode success `T` or throw the envelope error.
public func decodeOrThrow<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    if let err = try? JSONDecoder().decode(CoreError.self, from: data),
       (try? JSONDecoder().decode(OkFlag.self, from: data))?.ok == false
    {
        throw CoreCallError.failed(err.message)
    }
    return try JSONDecoder().decode(type, from: data)
}

struct OkFlag: Decodable { let ok: Bool }

public enum CoreCallError: Error, Sendable {
    case failed(String)
    case badUTF8
}
