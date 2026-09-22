// RustCore.swift — thin Swift wrapper over the ostmac-core C ABI.
import COstMac
import Foundation

public enum RustCore {
    public static func version() -> String {
        String(cString: ostmac_version())
    }

    public static func initialize() -> Int32 { ostmac_init() }

    public static func status() throws -> StatusResponse {
        try call(ostmac_status(), as: StatusResponse.self)
    }

    public static func deviceStart() throws -> DeviceStart {
        try call(ostmac_device_start(), as: DeviceStart.self)
    }

    public static func devicePoll(session: String) throws -> DevicePoll {
        try session.withCString { ptr in
            try call(ostmac_device_poll(ptr), as: DevicePoll.self)
        }
    }

    public static func chats(limit: Int32 = 20) throws -> ChatsResponse {
        try call(ostmac_chats(limit), as: ChatsResponse.self)
    }

    public static func trouterStart() -> Int32 { ostmac_trouter_start() }
    public static func trouterStop() -> Int32 { ostmac_trouter_stop() }

    public static func trouterPoll() throws -> TrouterPoll {
        try call(ostmac_trouter_poll(), as: TrouterPoll.self)
    }

    // Take ownership of a Rust-allocated C string, decode, free.
    static func call<T: Decodable>(
        _ raw: UnsafeMutablePointer<CChar>?, as type: T.Type
    ) throws -> T {
        guard let raw else { throw CoreCallError.failed("null from core") }
        defer { ostmac_free(raw) }
        guard let data = String(cString: raw).data(using: .utf8) else {
            throw CoreCallError.badUTF8
        }
        return try decodeOrThrow(type, from: data)
    }
}
