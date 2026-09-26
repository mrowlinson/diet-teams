# TOP10-SHARE-PROOF — macOS screenshare that works (lane top10-share)

Base: main @ 700ffe9. Scope: screenshare path ONLY.

## Research #7 verdict

- BetaNews 2026-07-12 (Sofia Wyciślik-Wilson): "Microsoft Teams has a known
  issue affecting screen sharing on macOS" — MS acknowledged blank screen
  when sharing on macOS prior to Tahoe 26.4; proper fix "next month"; interim
  workaround = enable **"Use Mac OS native sharing"** (Teams Settings >
  General > Screen sharing). URL: https://betanews.com/article/microsoft-teams-has-a-known-issue-affecting-screen-sharing-on-macos/
- Takeaway: the NATIVE macOS capture path is the reliable one. Better Teams
  builds on it exclusively: ScreenCaptureKit engine + native system picker,
  no custom capture path to go blank.

## Build (prior om-screenshare + this lane's gaps)

Prior (verified present, cited):
- Native picker: `SCContentSharingPicker.shared` + `.present()` —
  `swift/Sources/OstMacCore/ScreenShare.swift:281,288` (modes
  singleDisplay/singleWindow/singleApplication).
- Preflight (prompt-free, never hangs): `CGPreflightScreenCaptureAccess()` —
  ScreenShare.swift:44; `status()` wiring :47-49.
- One-click fix: `privacyURL` (Privacy_ScreenCapture deep link) :52-53,
  "Open Privacy Settings" button in tile :682-683.
- Failure evidence rule: denied set only on failure w/ preflight false
  (:333-339, :373-382); refresh alone never denies.

This lane:
- No-blank guarantee, pure + tested: `ScreenShareSummary.tileContent`
  (:203-208) + `ScreenShareTileContent` (:211-214); tile renders via it
  (:605-607). Every phase x frame combo -> preview or status placeholder;
  live-without-frame shows "Live" word, never silence.
- `--share-denied` hold fixed: `refreshPermission()` re-probed the seed away
  on granted boxes (this box grants the dev identity); now holds (:259-266).
- `--show-av-share` shot hook: ScrollViewReader + scrollTo("screenshare")
  in AvPanelView; flag doc in App.swift header.

## Accept

- Preflight detects missing perm + deep-links fix (test):
  `testStatusReflectsPreflight` (status==denied iff preflight false) +
  `testPrivacyURLTargetsScreenRecording` (Privacy_ScreenCapture).
- Picker is native API: ScreenShare.swift:281 (`SCContentSharingPicker.shared`),
  :288 (`.present()`).
- Fallback states tested: `testTileContentPreviewOnlyWhenLiveWithFrame`
  (all 6 phases x frame/no-frame), `testPlaceholderStatusNeverEmpty`,
  plus pre-existing `testStatusWords`/`testDeniedHint`.

## Tests

- `swift test --filter ScreenShareTests`: 23 tests, 0 failures.
- `swift test --filter AvPanelTests`: 22 tests, 0 failures.
- `swift build` (debug) + release app build: clean (only pre-existing
  DropQuick/FocusSync Swift-6 warnings, untouched files).
- Full gate: parent-side post-merge (box pegged).

## Shots (window-id `screencapture -l`, never activated; viewed; zero real data)

- `docs/shots/top10-share-tile.png` — share tile scrolled into view: Off
  placeholder + "Share Screen…" button (`--show-av --show-av-share`).
- `docs/shots/top10-share-denied.png` — denied path: "Screen Recording is
  off — sharing needs it." + guidance + "Open Privacy Settings" one-click
  fix (`--show-av --show-av-share --share-denied`).
- Script: `tmp/scratch-share/shot-one.sh` (+ `winlist` helper).
- No live-capture shot: engine never auto-starts capture; live needs a real
  user pick in the system picker (no input synth per shot rules).

## Files

- touch: `ScreenShare.swift` (+tileContent/hold), `AvPanelView.swift`
  (+Reader/scroll hook), `App.swift` (+1 flag-doc line),
  `ScreenShareTests.swift` (+3 tests).
- new: `docs/shots/top10-share-{tile,denied}.png`, `tmp/TOP10-SHARE-PROOF.md`,
  `tmp/scratch-share/*` (untracked scratch).
