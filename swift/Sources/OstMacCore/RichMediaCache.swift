// RichMediaCache.swift — om-richmedia: memory + disk image cache.
//
// Keyed by URL+message-id (sha256 hex), so paging (prepend) and streaming
// (upsert) re-render the same bubbles without refetching. In-flight
// requests dedupe: N bubbles awaiting the same key share one fetch.
// Memory is an NSCache (64 MB); disk persists across launches.
import CryptoKit
import Foundation

public enum MediaFetchError: Error, Sendable {
    case failed(String)
}

public actor RichMediaCache {
    public static let shared = RichMediaCache()

    /// Byte source for a URL. Default handles `demo://` fixtures + core.
    public typealias Fetcher = @Sendable (String) async throws -> Data

    private let memory = NSCache<NSString, NSData>()
    private var inFlight: [String: Task<Data, Error>] = [:]
    private let diskDir: URL?

    public init(memoryLimitMB: Int = 64) {
        self.init(diskDir: Self.defaultDiskDir(), memoryLimitMB: memoryLimitMB)
    }

    public init(diskDir: URL?, memoryLimitMB: Int = 64) {
        self.diskDir = diskDir
        memory.totalCostLimit = memoryLimitMB * 1024 * 1024
    }

    public static func defaultDiskDir() -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let dir = base.appendingPathComponent("OstMac/MediaCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Default fetcher: offline `demo://` fixtures, else blocking core FFI
    /// (detached so the actor never blocks on network).
    public static func defaultFetch(url: String) async throws -> Data {
        if url.hasPrefix("demo://") {
            return try DemoMedia.data(for: url)
        }
        return try await Task.detached {
            try RustCore.mediaFetch(url: url).data
        }.value
    }

    /// Stable key: sha256 hex of `messageID + "\n" + url`.
    public static func key(url: String, messageID: String) -> String {
        let input = Data((messageID + "\n" + url).utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    /// Memory, then disk. Nil when nothing is stored (no fetch).
    public func cached(url: String, messageID: String) -> Data? {
        let k = Self.key(url: url, messageID: messageID)
        if let m = memory.object(forKey: k as NSString) { return m as Data }
        if let d = readDisk(key: k) {
            memory.setObject(d as NSData, forKey: k as NSString, cost: d.count)
            return d
        }
        return nil
    }

    /// Cached bytes, fetching once on miss. Concurrent callers for the same
    /// key share the in-flight fetch; failures are not cached.
    public func data(
        url: String, messageID: String,
        fetcher: @escaping Fetcher = RichMediaCache.defaultFetch
    ) async throws -> Data {
        let k = Self.key(url: url, messageID: messageID)
        if let hit = cached(url: url, messageID: messageID) { return hit }
        if let t = inFlight[k] { return try await t.value }
        let task: Task<Data, Error> = Task { try await fetcher(url) }
        inFlight[k] = task
        do {
            let d = try await task.value
            memory.setObject(d as NSData, forKey: k as NSString, cost: d.count)
            writeDisk(key: k, data: d)
            inFlight[k] = nil
            return d
        } catch {
            inFlight[k] = nil
            throw error
        }
    }

    public func clearMemory() {
        memory.removeAllObjects()
    }

    private func diskURL(key: String) -> URL? {
        diskDir?.appendingPathComponent(key, isDirectory: false)
    }

    private func readDisk(key: String) -> Data? {
        guard let u = diskURL(key: key) else { return nil }
        return try? Data(contentsOf: u)
    }

    private func writeDisk(key: String, data: Data) {
        guard let u = diskURL(key: key) else { return }
        try? data.write(to: u, options: .atomic)
    }
}
