# teams-frame FULL — proof

Lane: `lanes/teams-frame-full`. Base: main @ 063cb42.
Status: **ready-for-owner-login**. DISPLAY ONLY — agent never clicked,
typed, or authenticated; only pre-login page loads + screenshots observed.

## Run command (owner)

```sh
cd /Users/mrowlinson/Projects/BetterTeams/tmp/wt-teams-frame-full
open "swift/.build/release/Better Teams.app" --args -ApplePersistenceIgnoreState YES --show-teams-frame
```

- Seed state shows "No app configured" guidance (placeholder, no webview).
  Paste a real entity deep link in the URL field + Load (stays in-frame,
  no re-auth), or launch directly with it:
  `--teams-frame-url 'https://teams.microsoft.com/l/entity/<APP_ENTITY_ID>?label=<LABEL>'`
- `--teams-frame-full` bypasses crop (fallback).
- `--teams-frame-calibrate` overlays draggable red crop guides + live
  `left/top` badge; values print on each release
  (`[teams-frame] calibrate: left=… top=…`).
- View → Kill App Frame → footprint log line + placeholder + Reopen.
- `-ApplePersistenceIgnoreState YES` skips crash-restore prompts from
  raw-binary dev launches.

## Architecture deltas (proto → full)

All frame code in `swift/Sources/OstMacCore/TeamsFrame.swift` (917 lines,
was 302). `App.swift` Window block passes launchURL/fullFrame/calibrate;
no other core files touched.

- Registry (`TeamsFrameApp` :154, `TeamsFrameRegistry` :172): Codable
  `[TeamsFrameApp]` as JSON Data in UserDefaults (`teamsFrameApps`;
  selection in `teamsFrameSelectedAppID`). Missing/corrupt/empty → 1
  placeholder seed entry (`sample-app`, `<APP_ENTITY_ID>`, no org URLs).
  Per-app `crop` is optional, nil → v0 (68/48).
- Switcher: native SwiftUI `Picker` + `.pickerStyle(.menu)` (AppKit
  `NSPopUpButton` under the hood) at :712, + TextField catalog URL entry
  + Load button. Both navigate the SAME webview (`updateNSView` compares
  against `coordinator.lastLoadedURLString`, :476 — SPA in-page nav never
  double-loads; same pool+store → no re-auth). `selectApp` :335 persists +
  clears custom override; `loadCustomURL` :345 validates (blank/unparseable
  rejected with log).
- Placeholder guard (found live, see Bugs): seed URL contains `<>`, which
  `URL(string:)` rejects → blank frame with zero feedback. Now
  `isPlaceholderURL` (:111) shows `TeamsFramePlaceholderView` (:778)
  instead; no webview is created until a loadable URL is set.
- Escapes YANKED: `escapeDecision(url:isMainFrame:)` (:96) matrix —
  allowed→allow; non-allowlisted top-level→yank (cancel + native
  `NSAlert` "Open in Browser? / Stay Here", opens via NSWorkspace);
  non-allowlisted subframe→log+allow (app iframes/CDNs must not break).
  Log lines kept: `ESCAPE (yanked, top-level)` / `(allowed, subframe)`.
- WKUIDelegate: `createWebViewWith` (:592) intercepts only target-less
  opens (`interceptsPopup`, unit-tested) → coordinator-built WKWebView
  (same config → SSO cookies) presented as modal `.sheet`
  (`TeamsFramePopupSheet` :800) with Close (Esc); `webViewDidClose`
  dismisses. JS alert/confirm/prompt → native NSAlert panels.
- Downloads: non-renderable responses → `.download` policy →
  `WKDownloadDelegate.download(_:decideDestinationUsing:…)` (:570) →
  NSSavePanel rooted at `~/Downloads` (`TeamsFrameDownloads` :230;
  filename sanitized, unit-tested).
- Lifecycle (`TeamsFrameStore`): lazy (pool/store/webview only after
  surface appear; fresh store holds no web objects — tested); hide
  (`deactivate`) sets `suspended`, calls `stopLoading` +
  `removeAllScriptMessageHandlers` on the weak `activeWebView`, keep-alive
  still honored; NO process prewarm at app launch (deliberate — cold-start
  surface stays cold, documented in class comment); `destroy` (:404) logs
  `footprint before destroy: X MB resident` via `task_info`
  (`TeamsFrameFootprint.residentMB` :214, best-effort nil-safe), then nils
  pool/store/popup. `suspended`/`keepAliveArmed` readbacks tested.
- Calibrate overlay (`TeamsFrameCalibrateOverlay` :851): 14pt grab strips
  + 2pt red guides + live badge; clicks pass through elsewhere.

## Registry schema

```json
[{"id":"sample-app","label":"Sample App",
  "entityURL":"https://teams.microsoft.com/l/entity/<APP_ENTITY_ID>?label=Sample",
  "crop":null}]
```

`crop` omitted/null → v0. Keys: `teamsFrameApps` (JSON Data),
`teamsFrameSelectedAppID` (String), `teamsFrameKeepAliveMinutes` (Int,
default 15, 0 = instant destroy on hide).

## RAM/CPU measures (live, pre-login, release build)

Login page loaded (`--teams-frame-url https://teams.microsoft.com/`):
`webview created` → `loaded: …/v2/` → `loaded: login.microsoftonline.com…
authorize` (allowlisted, no yank). Two RSS samples 45s apart, IDENTICAL —
no growth; CPU 0.0% on every process (truly idle):

| process | RSS MB | %CPU |
| app (OstMac, whole app) | 141.7 | 0.0 |
| WebContent (page) | 600.8 | 0.0 |
| WebContent (2 aux) | 76.3 + 16.0 | 0.0 |
| Networking / GPU | 52.7 / 31.1 | 0.0 |
| frame web total | ~776.9 | 0.0 |

Frame idle ≈ 777 MB web processes (Teams v2 login shell is heavy; stable,
zero CPU). App-side 142 MB. Guidance/seed state spawns NO WebKit children
(no webview until a loadable URL — verified: zero `com.apple.WebKit.*`
children in seed run).
Post-destroy MB: NOT measured live — GAP (agent cannot trigger window
close/menu headlessly: SwiftUI windows reject AppleScript `close` (-1708),
System Events keystroke needs accessibility). Footprint line itself
verified live in test runner (`[teams-frame] footprint before destroy:
50.9 MB resident`). Owner protocol: open frame → View → Kill App Frame →
read `footprint before destroy` + Activity Monitor after.

## Timer audit (zero polling while hidden)

`grep -n "NSTimer|Timer.|Task.sleep|repeats" TeamsFrame.swift` → exactly
2 hits: the doc comment + :392 `Timer.scheduledTimer(…repeats: false)`
(one-shot keep-alive, justified: the keep-alive feature IS a single
deferred destroy, not polling; invalidated on activate/destroy).
Zero `Task.sleep`. Remaining `Task { @MainActor … }` hops are
event-driven delegate callbacks, never loops.

## Owner-login protocol

1. Run the command above; paste the entity deep link + Load.
2. Microsoft Sign in renders (agent-verified 2026-09-26, see
   `tmp/teams-frame-full-loaded.png` — owner-viewed only, NOT committed;
   also `tmp/teams-frame-full-front.png` seed/switcher shot,
   `tmp/teams-frame-full-calibrate.png` guides shot).
3. Crop check: with `--teams-frame-calibrate`, drag guides over the
   post-login rail/header; report printed insets.
4. Kill check: View → Kill App Frame → footprint line + placeholder.
5. Report: crop insets + post-destroy MB (see gap above).

## Keys / flags / logs

- Flags: `--teams-frame-url`, `--show-teams-frame`, `--teams-frame-full`,
  `--teams-frame-calibrate`.
- stdout tags: `activate`, `webview created`, `switching frame to`,
  `app selected:`, `custom URL loaded in frame:`, `started:`, `loaded:`,
  `load failed:`, `ESCAPE (yanked, top-level):`,
  `ESCAPE (allowed, subframe):`, `POPUP:`, `popup presented/closed`,
  `DOWNLOAD:`, `download →/cancelled:`, `calibrate:`, `deactivate:`,
  `footprint before destroy:`, `DESTROYED`. NOTE: raw-binary stdout is
  block-buffered — capture via `script -q <log> <binary> …` (pty,
  line-buffered); SIGTERM loses buffered lines.
- Yank alert buttons: "Open in Browser" / "Stay Here".

## Gaps (unchanged from proto unless noted)

- Crop v0 still UNMEASURED (owner calibrates post-login; overlay provided).
- Media entitlements untouched (camera/mic/screen-share expected broken).
- Notifications not bridged. No catalog-store UI (registry + URL entry
  suffice, per scope). Live destroy/yank-alert/popup/download click-paths
  are owner-side (agent ran pre-login loads only; decisions unit-tested).

## Bugs found while proving (fixed on lane)

1. Seed placeholder URL (`<…>`) → `URL(string:)` nil → silent blank
   frame. Fixed: placeholder guidance view, no webview until loadable.
2. `URL(string:)`-nil custom entry → same blank. Fixed: `loadCustomURL`
   validates + logs `BAD CUSTOM URL`.
3. (Harness) stdout block-buffered under redirect; SIGTERM drops logs.
   Workaround: `script -q` pty capture.
4. (Unrelated flakes, untouched areas, green on re-run): rust
   ostmac-core 1–2 fails intermittently (3/3 green after); ContactsTests
   `testStaleCompletionDropped` once under load (17/0 alone).

## Gate

- `TeamsFrameTests`: 36 tests green (18 proto + 18 new: registry 7 incl.
  placeholder detect, escape matrix, popup/download seams 4, lifecycle 5,
  calibrate flag).
- Full `scripts/test.sh` green 2026-09-26 on final code: cargo ost
  274+274+1+1 / 0, ostmac-core 197 / 0, swift OstMacCore 2170 (1
  pre-existing skip) / 0, MCP 26 / 0.
