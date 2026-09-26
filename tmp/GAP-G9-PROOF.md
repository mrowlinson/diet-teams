# PROOF gap-g9 (jump-to-context harden)

- lane: lanes/gap-g9. wt: tmp/wt-gap-g9. base: main @ 700ffe9.
- spec: tmp/TOPTEN-AUDIT.md G9. scope: jump path ONLY.

## Demand vs delivered

1. Kill silent plain-open fallback → id-mismatch banners "message no
   longer available". SHIPPED + shot.
2. Log id-mismatch rate in Diagnostics. SHIPPED + shots (both verdicts).
3. Fix Graph-hit-id vs native-history-id mapping if diverged.
   NO CODE CHANGE: zero live evidence of divergence (token dead, see
   Gaps); any remap/fuzzy match without live ids risks landing on the
   WRONG bubble, worse than a clear miss message. Provenances pinned
   below; the shipped banner + mismatch rate are the instruments that
   will reveal divergence live, with real ids in hand.
4. Accept: live Graph search → pick hit → lands on exact bubble (shot);
   else mock + owner-step note. MOCK (demo verdict funnel) + owner
   steps. The viewport-landing half is blocked by a PRE-EXISTING
   scroll freeze (see Finding F1), not by this lane.

## Impl

- `ConversationStore` (gap-g9 verdict): every valid-id seek/open-with-seek
  runs to a verdict. Found → `jumpTargetID` + `seekLanded`. Unfound with
  budget exhausted or no cursor → `jumpMissedID` + `lastMissedID` +
  `seekMissed` (never a silent plain open). Page errors surface `error`
  with no miss verdict (network failure ≠ id mismatch) but still count
  the attempt. Blank ids / no open chat: no-op, no count, banner
  superseded. Counters session-wide; armed miss cleared by open/close/
  seek/showDemo; `lastMissedID` cleared on account switch only.
- `ChatTimelineView`: `DietBanner(.warning, "Message no longer
  available")` above the scroll while `jumpMissedID` armed, ✕ =
  `clearJumpMissed()`. Jump scroll deferred + pre-armed jumps honored
  on appear (same funnel; see F1 for why neither is pixel-verified).
- `DiagnosticsFormat.seekLine(attempted:landed:missed:)`: `no jumps yet`
  at zero, else `N attempts · L landed · M missed (R%)`.
- `DiagnosticsView`: new "Message jump" section + `JumpDiagRow`
  (observes `state.conv`; ONLY surface for the mismatch rate) with a
  "Last miss" id row.
- Shot hooks (demo offline): `--show-jump-missed` (bogus-id seek →
  banner + miss verdict), `--show-jump-landed` (mid-thread in-memory
  seek → landed verdict).

## Id mapping (no code change)

- Graph search id: `rust/ost/src/api/search.rs:127` — `resource.id` of
  the Graph `chatMessage` hit.
- Native history id: `rust/ost/src/api/chat.rs:1464` — `NativeMessage.id`
  from the Skype-space `/v1/users/ME/conversations/{id}/messages` fetch.
- Two backends; namespaces never compared live (token dead). No mapping
  fix applied per above.

## Tests

- New `JumpSeekTests` (6): miss arm + counters, blank no-count +
  supersede, land clears miss, dismiss keeps counters, close/showDemo
  clear, account-switch clears record.
- Updated `MessageSearchTests.testSeekMissingWithoutCursorArmsMiss`
  (was `...StaysNil` silent-noop contract).
- `DiagnosticsTests.testSeekLine` (zero line, 25% line, error-attempt
  33% rounding line).
- Focused: JumpSeek+MessageSearch+Diagnostics = 27 tests, 0 failures.
- Adjacent (touched store): Conversation+ConvRichUITests+Activity = 75
  tests, 0 failures.
- `swift build` + release green (standing macOS-27-vs-14 prebuilt-.a
  link warnings only; .a md5 f8886a17…, staged from main tip, Rust
  untouched; one standing Swift-6-mode warning in untouched
  `richDemoMessages`). Full gate parent-side post-merge.

## Shots (demo mode, zero real data; window-id captures, viewed)

- `docs/shots/gap-g9-jump-missed.png`: --demo --show-jump-missed →
  warning banner + ✕, thread plain-open behind it (wid 4032).
- `docs/shots/gap-g9-diagnostics-missed.png`: + --show-diagnostics →
  Message jump `1 attempts · 0 landed · 1 missed (100%)` + Last miss
  `shot-missing-bubble` (wid 4046, scrolled).
- `docs/shots/gap-g9-diagnostics-landed.png`: --demo --show-jump-landed
  --show-diagnostics → `1 attempts · 1 landed · 0 missed (0%)`
  (wid 4058, scrolled). The seek→land→count funnel end-to-end.

## Finding F1 (pre-existing, out of scope): timeline scroll frozen

Viewport landing is unverifiable in this env because ALL programmatic
scrolling of long demo threads fails identically on BASE and lane:

- 9/9 long-thread launch viewports sat at the head: settle-only
  (--show-catchup), --scroll-to (pre-existing flag), and jump seeks —
  on lane AND on the Sep-25 main binary (no lane code).
- Pill-tap ("Jump to latest", post-layout, base+funnel code): state
  updated (pill dismissed) but viewport frozen — proxy.scrollTo no-op.
- Synthetic wheel (order-verified clear path, RMSE 87 ≈ identical):
  viewport frozen. Same wheel tool moves the Diagnostics Form in the
  same build → freeze is timeline-specific, not env input routing.
- Box runs macOS 27.0 beta (26A428); SwiftUI regression possible.
- Attempted + REVERTED: staged jump-walk (realized-row hops), onAppear
  pre-arm landing, handler deferral. None moved the viewport; the walk
  is out (unverifiable + yank risk), the 6-line pre-arm branch +
  deferral stay (logic-correct, same funnel, zero risk when proxy
  works). Post-layout proxy health stays UNTESTED (no clean trial).
- Settle is equally affected (om-scroll territory, not jump path).

## Gaps / owner steps

1. Live Graph verification BLOCKED: stored tokens expired
   (expires_at 1790406106 < now 1790422708) and refresh failed
   (`teams-cli whoami` → "Token refresh failed… Run 'teams-cli
   login'"). No user-token churn attempted.
2. Owner live re-verify (after login + on stable OS): Graph search →
   pick hit → bubble centers (F1 may be beta-only); miss rate in
   Diagnostics; if rate climbs, compare `teams-cli search` msg ids vs
   `teams-cli read` native ids and file the mapping fix.
3. Env note: 5 system Problem Reporter dialogs (sys daemons, NOT the
   app — no OstMac crash log) were moved to x=1900 to clear the event
   path; SecurityAgent prompt at 1063,338 untouched (not lane's).

## Files

- M swift/Sources/OstMacCore/ConversationStore.swift (+miss/counters)
- M swift/Sources/OstMacCore/ChatTimelineView.swift (+banner, pre-arm,
  deferral)
- M swift/Sources/OstMacCore/Diagnostics.swift (+seekLine)
- M swift/Sources/OstMac/DiagnosticsView.swift (+section/row)
- M swift/Sources/OstMac/App.swift (+2 shot flags)
- M swift/Tests/OstMacCoreTests/MessageSearchTests.swift (contract flip)
- M swift/Tests/OstMacCoreTests/DiagnosticsTests.swift (+seekLine)
- N swift/Tests/OstMacCoreTests/JumpSeekTests.swift
- N docs/shots/gap-g9-*.png (3)
