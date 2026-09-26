# GAP-G2 PROOF — side-by-side accounts

- Lane: `lanes/gap-g2`. Base: main @ 008b27f.
- Spec: tmp/TOPTEN-AUDIT.md G2 (L).

## Accepts

1. "Open in new window" on account in switcher.
   - `AccountSwitcherView` gains an "Open in New Window" submenu (one row
     per account, incl. active). One-click switch rows untouched.
   - `AppState.openAccountWindow(accountID:)` → registry + window value;
     `RootView.onChange(pendingAccountWindowID)` → `openWindow(value:)`.
   - Scene: `WindowGroup(id: accountWindowID, for: String.self)`
     (`AppIdentity.accountWindowID = "account-window"`).
2. Both windows live-update independently.
   - Feed fan-out ×2, same rules decision, never re-decided:
     - live leg: `handleRealtime` → `accountWindows.ingest` (nil stamp
       resolves to active; active-account windows take live events).
     - background leg: `handleBackgroundEvent` → window graph owns the
       event (list bump + open-conv bubble + window-local unread)
       instead of the switch roll-up; banner still posts.
   - Window graph: per-profile list fetcher (no flip), stamped conv +
     flip-flop runner (history/sends/reacts/edits/deletes land on the
     window's account), NullDockBadge unread, per-account pins/saves.
   - Main selection never moves for window traffic (registry routes by
     account; `PopOutStore` untouched).
3. Closing 2nd loses no state.
   - `closeAccountWindow`: graph unread merges into `bgRollup` (new
     `BackgroundUnreadRollup.ingest`, additive) + drains locally (never
     double-counted); registry keeps the graph cached (selection,
     loaded bubbles, pins/saves); drafts live in the shared pop-out
     cache. Re-open restores with no refetch (list `.task` loads only
     from `.loading`).
   - Registry: re-open refocuses (one window per account), `drop` on
     remove-account (live window renders removed placeholder).

## Tests

- New `swift/Tests/OstMacCoreTests/GapG2Tests.swift`: 25 tests, all pass.
  - Gate: direct (unseeded/active/nil/blank), flip-flop sequence,
    op-throw still flips back, flip-to failure skips op, flip-back
    retry+record, setActive record/no-record-on-failure.
  - Runners: direct passthrough, recording notes.
  - Graph: conv stamping (account + runner identity), ingest bumps
    list + accrues unread, open-chat bubbles without unread, skip
    accrues nothing, g1-stamped arrival end-to-end into conv.
  - Registry: open/reopen/close/drop, graph identity across reopen,
    blank refuse, stamp routing, nil-stamp active resolve, closed
    refuses.
  - Roll-up merge: additive + junk dropped.
- Neighbors green: PopOut + GapG1 + Conversation + AccountStore +
  ChatList = 129 tests, 0 failures.
- `swift build` (all products): complete.

## Mechanism notes

- `AccountProfileGate` (OstMacCore): one lock serializes switches /
  restore / flip-flops; records active so flip-backs land on the
  CURRENT active after an interleaved switch. Fail-open when unseeded.
- `AccountWindowRunner` (App): feed pause → gated flip → op → flip-back
  → resume + coalesced resync (the pause's silent drain would otherwise
  swallow live events; ≤2s stale worst case). Pause skipped when the
  feed is already stopped.
- `ConversationStore`: 13 core sites wrapped via `coreHop`; nil account
  = direct (behavior unchanged for main + pop-outs).

## Known limits (v1, by design)

- Window-2 Shared/Notes tabs stay un-opened (inert): their fetches are
  active-profile and must not show the wrong account's files.
- No leave/block from the window (no UI entry; same FFI reason).
- Inactive-account windows update on the g1 30s sweep cadence, not
  trouter-instant.
- Switching main TO a window-visible account splits counts (window keeps
  its own, main starts clean): no loss, no double.
- NOT live-verified here: real two-account flip-flop (needs tokens),
  pixel shots (parent-side post-merge).

## Files

- New: `swift/Sources/OstMacCore/AccountCoreRunner.swift`,
  `swift/Sources/OstMacChatList/AccountWindows.swift`,
  `swift/Tests/OstMacCoreTests/GapG2Tests.swift`.
- Edit: App.swift (scene, gate+registry, runner, fan-out ×2, window
  views), ConversationStore.swift (13 sites), AccountSwitcherView.swift
  (submenu), AppIdentity.swift (id), BackgroundAccounts.swift (merge).
