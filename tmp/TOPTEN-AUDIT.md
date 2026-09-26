# TOP-10 AUDIT — shipped vs research demand (verification-only)

- Base: main @ 404a7aa (worktree `tmp/wt-topten-audit`, branch `lanes/topten-audit`).
- Method: proofs read, cited impl files opened, each demand bullet checked vs code (file:line below).
- Verdicts: 0 SUFFICIENT / 4 GAP.

## Per-item verdicts

| # | Demand | Verdict | Shipped (code) | Missing |
|---|--------|---------|----------------|---------|
| 2 | multi-account side-by-side + unified notifs | GAP | Sequential switch, 1 active profile (`AccountStore.swift:203` `switchTo`; single global `RealtimeFeed`, `App.swift:411`; `feed.stop()` on switch `:1134`, `feed.start()` after `:1182`) | Side-by-side (no 2nd main window; popouts = active-account chats only); unified notifs (zero cross-account code — grep allAccount/unified: no hits); inactive accounts get no events, no unread roll-up |
| 3a | DND/Focus respect | GAP | Teams-presence DND (`MentionAlert.isDND`, `App.swift:2082`); Focus fold-in (`FocusSync.swift`, `localQuietNow` `App.swift:2069`) | Focus sync DEFAULT OFF (`FocusSync.swift:82-83`); mechanism = best-effort parse of private `~/Library/DoNotDisturb/DB/Assertions.json`, active shape never verified (`FocusSync.swift:8-16`); fails open = Focus users still buzzed |
| 3b | CallKit | GAP | Nothing | Zero CallKit symbols repo-wide (grep CXProvider/CXCall/CallKit: no hits) |
| 3c | Never miss calls | GAP | In-app call banner (`CallView.swift:527+`); missed calls → Activity feed (`ActivityStore.swift:348`) | No UNNotification for incoming calls (no Notifier/maybeNotify in CallView/CallCenter); no ring sound (no NSSound/AudioServices/AVAudioPlayer in src); app-backgrounded/minimized = call invisible except feed row |
| 4 | true multi-window (chats+channels+meetings+files) | GAP | Chat pop-outs (`PopOutStore.swift:66` `pop(chatID:)`; entry `ChatListSidebar.swift:275` + dbl-click; value WindowGroup `App.swift:269`) | Channels: no pop entry in Teams tab. Meetings: single Meeting window (`App.swift:248`), not per-meeting pop-out. Files/Shared: no pop-out anywhere. PopOutStore keyed by chatID only |
| 5a | offline index | GAP | `LocalSearchStore.swift` (303 lines, token index, OMIX persist) exists + tested | NEVER instantiated in App: only references are comments + `SavedMessages.swift:211` tokenizer reuse. Zero UI wiring |
| 5b | jump-to-context | GAP (partial ship) | `open(seekMessageID:)` + `seek()`, `seekMaxPages=8` (`ConversationStore.swift:79,145`); timeline scroll (`ChatTimelineView`) | Bounded 8-page page-back, then silent plain-open fallback; Graph hit ids vs native history ids unmapped; NEVER live-verified (token expired, per ja-search proof gaps) |
| 5c | sticky filters | GAP | Scope chip Chats/Messages (`JumpPaletteView.swift:169`) | `@State scope` (`:46`), no persistence, no saved filters, no recents (grep persist/UserDefaults/recent in palette: no hits) |
| 5d | instant | GAP | 350ms debounce (`JumpPaletteView.swift` debate ~:89+) | Online Graph only (`MessageSearchStore` live = core network, `App.swift:772-775`); offline path unwired so every keystroke-search pays network RTT |

## Gap specs

### G1 — background poll + unified notif roll-up for inactive accounts (M)
- Missing: any event path for non-active profiles; single feed bound to active profile (`App.swift:1285` subscribe; `RealtimeFeed` has no profile concept).
- Accept: sign in 2 accounts; message arrives on inactive acct; banner posts within 60s naming the account; switch shows unread 1. Falsifiable: `notifPosted` increments + banner userInfo carries account id while `activeID != msg.accountID`.
- Size: M (per-profile poll loop in Rust core or 2nd feed; rules snapshot per account; banner routing).

### G2 — side-by-side accounts (L)
- Missing: 2nd main window; all windows render active-profile stores.
- Accept: "Open in new window" on account in switcher; both windows live-update independently; closing 2nd loses no state.
- Size: L (per-window store graph or store keyed by profile; feed fan-out ×2).

### G3 — incoming-call system notification + ring sound (M)
- Missing: `CallView`/`CallCenter` never touch `Notifier`; zero audio playback code.
- Accept: app minimized, incoming call → UNNotification banner w/ Accept/Decline actions + audible ring until answered/timeout (≤ CallRingPolicy.timeout); deno: banner pixel-captured.
- Size: M (call category + actions in `Notifier.setup()`; ring via NSSound loop tied to phase machine; decline-from-banner path).

### G4 — CallKit (L)
- Missing: entire framework integration.
- Accept: incoming call shows native macOS call UI; responds to system mute/answer; recents integrate; DND/Focus handled by OS policy.
- Size: L. NOTE: overlaps G3 — CallKit subsumes the ring/banner need; do G3 first only if CallKit deferred.

### G5 — Focus respect on-by-default + verified (S)
- Missing: default-off + unverified parser (`FocusSync.swift:82`, `:8-16`).
- Accept: default ON for fresh installs; Focus ON → `focusActive==true` observed live on 2 OS versions (log line); parser failure → Diagnostics error, never stuck-quiet (already fails open).
- Size: S (flip default + live-verify matrices + Settings copy). Risk: private path may drift per OS — needs per-release re-probe.

### G6 — wire offline index into search (M)
- Missing: `LocalSearchStore` uninstantiated; no index-build trigger (no ingest hook), no UI fallback.
- Accept: airplane mode, search finds last week's message in <200ms (timed log); online results merge above offline; index persists relaunch (existing OMIX path).
- Size: M (index writer on ingest+history fetch; MessageSearchStore offline-first merge; palette source badge).

### G7 — sticky filters + recents (S)
- Missing: `@State scope` ephemeral; no saved queries.
- Accept: scope chip + last query restore on palette reopen; 5 recent searches persisted; clear-recents control.
- Size: S.

### G8 — channel/meeting/file pop-outs (M)
- Missing: pop-out entry + hosting for non-chat surfaces.
- Accept: channel row, meeting, file preview each pop to own window w/ live updates; re-pop focuses; close loses no state (same contract as E1-POPOUT accepts 3/7).
- Size: M (generalize PopOutStore key or 3 small registries; entries in Teams/meeting/file views).

### G9 — jump-to-context harden + live-verify (S)
- Missing: silent fallback + zero live evidence.
- Accept: live Graph search → pick hit → lands on exact bubble (shot); id-mismatch rate logged in Diagnostics; fallback shows "message no longer available" instead of silent top-open.
- Size: S (mostly live QA + fallback UX + mapping fix if ids diverge).

## TOP-5 gap ranking (demand pain × ship distance)

1. G1 unified notifs — #2's core pain (tenant-switch nightmare) is UNFIXED: switching exists but missing-while-away persists. Highest research weight.
2. G3 call banner+ring — "never miss calls" fully unshipped; in-app-only banner = the Mac no-sound complaint verbatim.
3. G6 offline index — code written, tested, then never wired; "instant full-context" fails on both adjectives.
4. G2 side-by-side — demanded explicitly; L cost keeps it below G1/G3 on value/effort.
5. G8 non-chat pop-outs — #4 half-shipped (chats done well: 19 PopOutTests, mirror+fanout pinned); channels/meetings/files remain.

## Adversarial notes

- Owner suspicion CONFIRMED in extent, not in kind: each item shipped its demo-able core (switch works, banners post, chats pop, Graph search returns) while the demanded HARD parts (background accounts, OS integration, offline, cross-surface) are absent.
- Bright spots (genuinely sufficient sub-parts, not full items): chat pop-out impl (E1-POPOUT accepts 1-9 evidenced); keyword alerts + 3-state levels (D2-ALERTS); Focus plumbing shape (correct fold-in, wrong default+unverified); ArchiveCodec/LocalSearchStore code quality (just unwired).
- No live-verification debt beyond G9: notif-live proof shows banner pixels BLOCKED by system auth (env, not code).
