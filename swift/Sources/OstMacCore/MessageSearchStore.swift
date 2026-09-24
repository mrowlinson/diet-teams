// MessageSearchStore.swift — om-ja-search lane: Graph MESSAGE search state.
//
// INPUT API (what the jump palette drives):
//   store.search(query:) — fresh search from window 0 (replaces hits)
//   store.loadMore()     — append the next window via next_from (deduped)
//   store.retry()        — re-run the last query (error-state Try Again)
//   store.clear()        — drop query + hits (blank query, scope switch)
import Foundation

/// Searches Teams messages via ostmac-core and pages the windows.
///
/// Default searcher calls `RustCore.search` (blocking FFI + network) on a
/// detached task. Tests inject a mock searcher.
@MainActor
public final class MessageSearchStore: ObservableObject {
    /// Sync search (runs off-main). Throws `CoreCallError` on core failure.
    public typealias Searcher = @Sendable (String, Int32, Int32) throws -> SearchResponse

    /// Server-ranked hits for the last submitted query (no client filter).
    @Published public private(set) var hits: [SearchHit] = []
    /// Fresh search in flight.
    @Published public private(set) var isSearching = false
    /// Next-window fetch in flight.
    @Published public private(set) var loadingMore = false
    /// Last failure (nil when clear).
    @Published public private(set) var error: String?
    /// Server total, when reported.
    @Published public private(set) var total: Int?
    /// True while another window exists.
    @Published public private(set) var more = false
    /// Cursor for the next window; nil = exhausted.
    public private(set) var nextFrom: Int?
    /// Last submitted query (trimmed; retry re-runs it).
    public private(set) var lastQuery = ""

    /// Graph's per-request hit cap (core clamps larger sizes to this).
    public nonisolated static let pageSize: Int32 = 25

    private let searcher: Searcher
    private var generation = 0

    public init(
        searcher: @escaping Searcher = { query, from, size in
            try RustCore.search(query: query, from: from, size: size)
        }
    ) {
        self.searcher = searcher
    }

    /// Fresh search from window 0; replaces hits. Blank queries clear
    /// without touching core. Stale completions are dropped, so fast
    /// typing always lands on the newest query.
    public func search(query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1
        let gen = generation
        guard !q.isEmpty else {
            hits = []
            isSearching = false
            loadingMore = false
            error = nil
            total = nil
            more = false
            nextFrom = nil
            lastQuery = ""
            return
        }
        lastQuery = q
        isSearching = true
        loadingMore = false
        error = nil
        let searcher = searcher
        do {
            let response = try await Task.detached {
                try searcher(q, 0, Self.pageSize)
            }.value
            guard gen == generation else { return } // superseded
            hits = response.hits
            total = response.total
            more = response.more
            nextFrom = response.next_from
            isSearching = false
        } catch {
            guard gen == generation else { return } // superseded
            isSearching = false
            hits = []
            total = nil
            more = false
            nextFrom = nil
            self.error = Self.message(for: error)
        }
    }

    /// True while the next window exists and no fetch is in flight.
    public var canLoadMore: Bool {
        more && nextFrom != nil && !isSearching && !loadingMore
    }

    /// Append the next window (overlap deduped by row id). No-op without
    /// a cursor or while a fetch is in flight. A mid-chain failure keeps
    /// the loaded hits with the error surfaced and the cursor intact —
    /// tapping again retries the same window.
    public func loadMore() async {
        guard canLoadMore, let cursor = nextFrom else { return }
        loadingMore = true
        error = nil
        let gen = generation
        let query = lastQuery
        let searcher = searcher
        do {
            let response = try await Task.detached {
                try searcher(query, Int32(cursor), Self.pageSize)
            }.value
            guard gen == generation else { return } // superseded
            hits = Self.merged(hits, response.hits)
            total = response.total
            more = response.more
            nextFrom = response.next_from
            loadingMore = false
        } catch {
            guard gen == generation else { return } // superseded
            loadingMore = false
            self.error = Self.message(for: error)
        }
    }

    /// Re-run the last query (empty-state Try Again). No-op without one.
    public func retry() {
        guard !lastQuery.isEmpty else { return }
        Task { await search(query: lastQuery) }
    }

    /// Drop the query + hits (scope switch back to chats).
    public func clear() {
        generation += 1
        hits = []
        isSearching = false
        loadingMore = false
        error = nil
        total = nil
        more = false
        nextFrom = nil
        lastQuery = ""
    }

    /// Pure append: new windows first, existing ids win on overlap.
    public nonisolated static func merged(_ old: [SearchHit], _ new: [SearchHit]) -> [SearchHit] {
        let known = Set(old.map(\.id))
        return old + new.filter { !known.contains($0.id) }
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}
