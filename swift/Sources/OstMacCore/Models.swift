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
}

public struct ChatsResponse: Decodable, Sendable {
    public let ok: Bool
    public let chats: [ChatItem]
}

public struct TrouterPoll: Decodable, Sendable {
    public let ok: Bool
    public let events: [AnyJSON]
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
