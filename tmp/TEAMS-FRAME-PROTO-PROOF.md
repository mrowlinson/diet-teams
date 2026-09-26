# teams-frame PROTOTYPE — proof

Lane: `lanes/teams-frame-proto`. Base: main @ 777c71f.
Status: **ready-for-owner-login**. DISPLAY ONLY — agent never clicked,
typed, or authenticated; only pre-login page loads observed.

## Run command (owner)

```sh
cd /Users/mrowlinson/Projects/BetterTeams/tmp/wt-teams-frame-proto
open "swift/.build/release/Better Teams.app" --args -ApplePersistenceIgnoreState YES --teams-frame-url 'https://teams.microsoft.com/l/entity/<APP_ENTITY_ID>?label=<LABEL>'
```

- Default URL (no flag value needed): `--show-teams-frame` opens
  `https://teams.microsoft.com`.
- `--teams-frame-full` bypasses the rail/header crop (fallback).
- Expect a one-time keychain prompt (`dev.ostmac.OstMac.klipy`):
  lane build is ad-hoc-signed, so macOS asks where the owner's
  dev-signed build would not. Allow/Deny both leave the frame working
  (frame never touches the keychain; the main window does).
- `-ApplePersistenceIgnoreState YES` skips the crash-restore prompt
  left by an early raw-binary launch during development.

## Architecture

- `swift/Sources/OstMacCore/TeamsFrame.swift` (new): config, store,
  webview, window content. No other core files touched except
  `AppIdentity.swift` (+1 window id).
- `swift/Sources/OstMac/App.swift`: "App Frame" Window (1100x750),
  View → Kill App Frame menu, `--show-teams-frame` /
  `--teams-frame-url` onAppear hook, `AppState.teamsFrame` store.
- Webview: `NSViewRepresentable` WKWebView, **dedicated
  WKProcessPool** + **own persistent WKWebsiteDataStore**
  (`forIdentifier: 3F2504E0-…`, isolated from BrowserAuthView's
  default jar; Teams cookies survive relaunch).
- UA: `applicationNameForUserAgent = "Version/17.4 Safari/605.1.15"`.
  REQUIRED — stock WKWebView UA gets
  `teams.microsoft.com/v2/unsupported-browser` (observed). With the
  suffix the real `/v2/` app loads (observed: login page renders).
- Escapes: navigation delegate allowlists teams + MS auth/content
  hosts (10 suffixes, boundary match, case-insensitive) and **logs +
  allows** the rest (`[teams-frame] ESCAPE (allowed, prototype): …`).
- Lifecycle: window appear → `activate()` (build pool/store, cancel
  timer); disappear → `deactivate()` (destroy now if
  `teamsFrameKeepAliveMinutes == 0`, else arm timer, default 15);
  View → Kill App Frame → notification → instant `destroy()` +
  stdout log. `destroy()` nils pool+store (dedicated pool orphans
  its web processes); placeholder offers Reopen (no relaunch).
- No preload. No entitlement changes.

## Crop v0 (UNMEASURED — owner must confirm)

`TeamsFrameCrop.v0 = left 68, top 48` (@1x, pt). Estimates from
public Teams-web layout, NOT measured live: pre-login there is no
Teams chrome, and only the owner may drive an authenticated session.

Measure protocol (owner, post-login): open the frame on the entity
deep link with `--teams-frame-full`, screenshot, measure the left
rail width and top header height in pt, update `TeamsFrameCrop.v0` +
this doc. If insets differ per app, crop becomes per-app config.

## Owner-login protocol

1. Run the command above with the entity deep link.
2. Microsoft Sign in renders in the App Frame window (agent-verified
   2026-09-26: sign-in card with Next button, see
   `tmp/teams-frame-front.png` — owner-viewed only, NOT committed).
3. Owner completes login + display check live. Crop check: left rail
   and top header should be clipped away; content fills the window.
4. Kill check: View → Kill App Frame → placeholder + stdout
   `[teams-frame] DESTROYED (pool orphaned)`.
5. Report: crop insets right/wrong + measured values.

## Keys / flags / logs

- Flags: `--teams-frame-url <url>`, `--show-teams-frame`,
  `--teams-frame-full`.
- UserDefaults: `teamsFrameKeepAliveMinutes` (default 15, 0=instant).
- stdout tags: `activate`, `webview created`, `started:`, `loaded:`,
  `load failed:`, `ESCAPE (allowed, prototype):`, `deactivate:`,
  `DESTROYED`. Kill-switch/keep-alive verified by unit test; live
  kill path exercised only via Reopen placeholder logic (owner
  runs the menu item in step 4).

## Media gaps (no entitlement changes, prototype)

- Camera/mic inside the frame: WKWebView media capture needs
  `NSCameraUsageDescription`/`NSMicrophoneUsageDescription` +
  user grant; Info.plist untouched, so in-app calls that need
  devices will fail or prompt-less deny. Display-only prototype:
  untested, expected broken.
- Screen share from inside the frame: needs ScreenCaptureKit /
  picker bridging — not present.
- SSO popups (`window.open` / new-window delegate): stock behavior
  (opens in same webview or dropped); no `WKUIDelegate`
  implemented. Downloads: stock delegate only, untested.
- Notifications from the web app: not bridged.

## Bugs found while proving (fixed on lane)

1. `pool`/`dataStore` not `@Published` → body never re-evaluated
   after `activate()`, webview never created. Fixed: both published.
2. Stock WKWebView UA → `/v2/unsupported-browser`. Fixed: Safari
   token suffix (regression test added).
3. Ad-hoc lane build + earlier raw-binary crash → AppKit restore
   alert blocks launch headlessly. Workaround: saved-state cleared,
   `-ApplePersistenceIgnoreState YES` in run command.

## Gate

- `TeamsFrameTests`: 18 tests green (allowlist, flags, keep-alive,
  destroy/reopen seams, UA regression, crop sanity). No live login.
- Full `scripts/test.sh` green 2026-09-26: cargo ost 274+274+1+1
  passed / 0 failed, ostmac-core 197 passed / 0 failed; swift
  OstMacCore 2152 (1 pre-existing skip) / 0 failures, MCP 26 / 0.
