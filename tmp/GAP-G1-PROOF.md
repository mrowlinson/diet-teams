# GAP-G1 PROOF — background events + unified notif roll-up for INACTIVE accounts

- Lane: gap-g1 (`lanes/gap-g1`, worktree `tmp/wt-gap-g1`). Base main @ 7b77540.
- Spec: `tmp/TOPTEN-AUDIT.md` G1. Scope: account/feed/notif-routing only; no UI switcher changes.

## Design (Swift 2nd feed, no Rust changes, no trouter disturb)

- Trouter is a single global connection bound to the active profile
  (`rust/ostmac-core/src/lib.rs` trouter_state); per-profile trouter would be
  a core re-architecture. G1 instead polls REST per inactive profile:
  `CoreReads.chats(limit:profile:)` loads each account's tokens by profile
  (same seam as per-account whoami/refresh, incl. refresh-on-expiry).
  No profile flips, live feed untouched.
- `BackgroundAccountPoller` (new `OstMacCore/BackgroundAccounts.swift`):
  30s sweep over non-active accounts, diffs last-message fingerprints
  (time|sender|preview) per chat, emits `BackgroundChatEvent`. First sight
  of an account seeds silently (no launch storm); empty chats seed but never
  emit; vanished chats forgotten silently; per-account fetch failure skips
  that account only (lastError kept, cleared on success).
- Profile concept added to the feed layer: `RealtimeMessage.accountID`
  (wire-compat `decodeIfPresent`, `stamped()` helper). Background events
  stamp the polled account; live events omit (nil = active, back-compat).
- Per-account rules snapshot (`BackgroundRules.snapshot`): global config
  with owner identity re-stamped (displayName always; MRI from the record's
  Teams user id, "" when unresolved — never the ACTIVE account's MRI).
  Mute/keyword/snooze sets stay global (chat ids tenant-unique in practice).
- Decision parity with the live path: same `ChatFilter.decide` (shared
  meeting-dedup window, keyed by chat), same blocked gate (groupness rides
  the polled row), same quiet snapshot (device-global), same alert stats,
  same shared `notifPosted`/`notifSkipped` counters. DND forced off (own
  Teams presence belongs to the active account — not a signal here).
  Background touches NOTHING active: no list/timeline/receipt/presence/
  mention ingest (those rebind on switch).
- Banner names the account: `NcDelivery.makeBanner(accountName:)` prefixes
  `[Work] …`; `Notifier.post(accountID:)` stamps `OMAccountID` into userInfo
  + scopes the thread (`acct:chat`, no cross-account merge). Locked screens
  redact fully (no account leak); preview-off keeps the account prefix.
- Roll-up: `BackgroundUnreadRollup` accrues .notify counts per inactive
  account; `resetStoresForAccount` drains the newly-active account's stash
  into the live `UnreadStore` (`ingestBackground`, additive) → switch shows
  unread N. remove-account drops snapshot + stash. Session-scoped (in-memory).
- Routing owns the account end-to-end: `dispatch` broadcasts forward
  `accountID`; banner click switches to a known foreign account first then
  jumps (unknown = stale banner, dropped); inline reply switches first then
  sends on the delegate queue (sync flip → send lands right); refused/failed
  switch fails loud, never cross-sends. Same in the Notifier-delegate
  fallback (`onOpenChat`/`onReply` now take the owning account).

## Accept mapping (spec G1)

1. 2 accounts, message arrives on inactive → banner within 60s naming the
   account: 30s ungated timer (fires minimized, unlike the 2s visible-only
   tick) + `[name]` title. Worst-case skew one interval.
2. Switch shows unread 1: roll-up stash → `ingestBackground` on switch.
3. Falsifiable: background posts increment the shared `notifPosted`
   (`handleBackgroundEvent`, same counter as live); banner userInfo carries
   `OMAccountID` while `activeID != msg.accountID` (`OmReplyInfo.userInfo`
   round-trip pinned in tests; live banners omit the key = active).

## Tests (25 new, all pass; neighbors green)

- New `swift/Tests/OstMacCoreTests/GapG1Tests.swift` (+`GapG1UnreadTests`):
  seed-silent, changed-fp emits w/ account fields, unchanged silent, active
  never fetched, new-chat emits, vanish forgotten, empty-chat silent,
  failure-isolation + error clear, drop/reset, msgID stable/distinct,
  snapshot stamps owner (+MRI-unknown fallback), snapshot drives own-skip /
  peer-notify decisions, roll-up note/take/drop/clear/totals, userInfo
  round-trip + active-omits, banner prefix / locked-redact / preview-off,
  dispatch broadcasts account (open+reply) + active-omits, account_id
  decode + stamped(), per-profile chats (tokens only under acct-b; acct-c
  throws), ingestBackground merge/badge/no-op/open-clears.
- `swift test --filter GapG1`: 25/25 pass.
- Neighbors (NcDelivery, Notif, NotifBadge, MarkUnread, FfiLaterB4Chats,
  Realtime, Rules, AccountStore, GapG3G5, MentionAlert, MuteHide,
  QuietHours): 0 failures. `swift build`: complete (warnings pre-existing).

## Files

- New: `swift/Sources/OstMacCore/BackgroundAccounts.swift`,
  `swift/Tests/OstMacCoreTests/GapG1Tests.swift`.
- Touched: `App.swift` (poller+timer, handleBackgroundEvent, handoff,
  open/reply account routing, maybeNotify/setupNotifier account params),
  `Realtime.swift` (accountID), `ReadCore.swift` + `RustCore.swift`
  (per-profile chats), `NcDelivery.swift` (accountID read, banner naming),
  `Notifier.swift` (account userInfo/thread, delegate threading),
  `Notifications.swift` (dispatch forwards account), `UnreadStore.swift`
  (ingestBackground).

## Live-verify note (owner step, needs 2 signed-in accounts)

- Sign in A + B (B inactive); send a message to B's chat; ≤60s a
  `[B-name] …` banner posts; `bgEvents`/`notifPosted` increment in
  Diagnostics; switch to B → unread 1 on that chat; click the banner from
  A → lands in B on that chat; inline-reply from the banner sends as B.
- Banner-pixel capture needs notification auth (same env gate as the
  notif-live proof); logic above is unit-pinned.
- Known edge: quiet-suppression counting for background events reuses the
  live helper's active-name backup (Diagnostics counter only; banner held
  correctly either way).
