# TOP10-CODE PROOF — #8 code-first messaging

Lane: top10-code. Branch: `lanes/top10-code`. Worktree: `tmp/wt-top10-code`. Base: main @ 7b77540.
Scope: composer + message render ONLY (Swift; no Rust changes).

## Tip

- `5428ff2` top10-code: #8 code-first messaging (39/39 + shot, neighbors green)
- proof: this file (committed below the tip)

## Research (#8 demand)

- TechCommunity thread 2349812 "Why does Teams always strip indentation when
  pasting text?" (58 replies per brief): the VS Code interaction is
  confirmed in-thread — "If I copy from Visual Studio Code and paste into
  Teams (on macOS) this problem happens. If I copy from TextEdit or Visual
  Studio and paste into Teams, the indentation is fine." Root cause class:
  the composer consumes the styled clipboard flavor and drops leading
  whitespace. Fix class delivered here: plain-text-first paste.
- HN "developer-hostile" sentiment: covered structurally — fenced blocks
  render as code (not literal backticks), multi-language highlight,
  indent-preserving send.

## Root causes found

1. Composer: both composers are plain `TextField`s (ConversationView
   composer + edit sheet, QuickComposerView message field), so AppKit stock
   paste already takes the `.string` flavor — the VS Code styled-flavor
   trap cannot fire. Locked in + rescued for styled-only clipboards.
2. Send: Swift `send`/`edit`/`quickSend`/scheduled paths only trimmed
   outer whitespace (interiors already intact); now all route through one
   normalizer (line endings only). NOTE (residual, out of scope): the wire
   wraps everything in `<p>` (`rust/ost/src/api/chat.rs`
   `send_message_with_client`) — HTML collapses newlines/indents in OTHER
   clients. Swift-side sends preserve bytes exactly (tested); a follow-up
   lane should emit `<pre>` for fenced blocks on the wire.
3. Render: no fence awareness (` ``` ` showed literally); `<pre>` was mono
   without colors; shortcodes/mentions/links mined inside code text.

## Build

- `swift/Sources/OstMacCore/CodeBlocks.swift` (new): line-based ```
  /~~~ fence parser → prose/code segments (fence lines consumed, code
  byte-exact, unclosed→end, 50-block cap); `sendBody` (CRLF/CR→LF +
  outer trim, interior verbatim); info-string → grammar map (36 langs +
  aliases: js/py/c++/sh/…).
- `swift/Sources/OstMacCore/CodePaste.swift` (new): pure
  `resolve(string:rtf:html:)` — `.string` wins; RTF via NSAttributedString;
  HTML via block→newline strip (indent kept, never space-collapsed);
  `normalize` (line endings only). `PlainPasteFallback` view modifier:
  intercepts Cmd+V ONLY when no `.string` exists but RTF/HTML does
  (append rescue; stock paste otherwise untouched). Wired to all 3
  composer fields.
- `swift/Sources/OstMacCore/CodeHighlight.swift` (new) +
  `HighlightJSSource.swift` (generated, embedded): highlight.js 11.10.0
  (BSD-3-Clause, 36 common grammars incl. swift/python/rust/typescript),
  run headless in JavaScriptCore → token runs → native AttributedString
  colors. Zero Swift package deps, offline, every failure degrades to
  mono (alignment-guarded, JS exceptions swallowed, 20K-char cap).
- `MessageRender.swift` (touch, additive): fence-less path bit-identical
  (guard); fenced path splits prose/code — prose keeps legacy styling,
  code gets mono + token colors (foreground ONLY, no wash) and zero
  mention/link/tick mining; `expandShortcodes` excludes fenced ranges;
  server `<pre>` blocks gain auto-detected colors in both paths.
- Send paths route via `CodeBlocks.sendBody`: `ConversationStore.send`,
  `.edit`, `App.quickSend`, `ScheduledSend.enqueue` (covers both fire
  paths). Forward/copy keep fences (content untouched).
- Shot hook (additive, demo-only): `--show-code` (App.swift: isDemo +
  preselect rich + 2 seeded fenced bubbles at tail, DemoData untouched).

## Engine pick (justification)

- highlight.js-in-JSC chosen over Swift-Syntax (Swift-only — demand is
  multi-language VS Code pastes — plus a heavy package dep and minutes of
  compile on a pegged box) and over WebView-per-bubble (breaks the native
  Text selection/menu bridge, per-bubble web processes). Headless-JSC
  keeps the native bubble, adds no Swift deps, and is unit-testable.

## Suites

- New: `Top10CodeTests` 39 tests, 0 failures.
- Neighbors (11 suites, all green): ConvRichUITests, ConversationTests,
  CopyForwardTests, EditDeleteTests, MentionHighlightTests, MentionsTests,
  QuickComposerTests, RenderParsePerfTests, RichConversationTests,
  RichMediaTests, ScheduledSendTests.
- `swift build` (all targets): green. Full gate runs parent-side
  post-merge (box pegged).

## Acceptance

1. Paste indented Swift from clipboard → sent message keeps indent:
   `testPasteIndentedSwiftSendKeepsIndent` (VS Code-style 3-flavor
   clipboard → string wins → demo send byte-exact, 4sp/8sp/tab).
2. Fenced block renders highlighted: shot below — received python +
   sent swift bubbles, fences stripped, mono + token colors, indents
   visible. Pixel-verified by lane.
3. Copy/forward keep fences; prose around code still styles (mention
   bold, links); code excludes mentions/links/shortcodes/ticks (tests).

## Shots (window-ID captures, --demo only, viewed)

- `tmp/TOP10-CODE-SHOT.png`: `--show-code` — rich thread tail with the two
  seeded fenced bubbles (python received, swift sent), highlighted.
- Script: `tmp/scratch-code/shot-code.py` (debug .app assemble + sign +
  winlist + `screencapture -l`; app terminated after).

## Files

- new: `CodeBlocks.swift`, `CodePaste.swift`, `CodeHighlight.swift`,
  `HighlightJSSource.swift` (generated), `Top10CodeTests.swift`,
  `tmp/TOP10-CODE-SHOT.png`, `tmp/scratch-code/shot-code.py`
- touch (additive): `MessageRender.swift`, `ConversationStore.swift`
  (send/edit), `ConversationView.swift` (2 fields), `QuickComposerView.swift`
  (1 field), `ScheduledSend.swift` (enqueue), `App.swift` (quickSend +
  --show-code hook + flag doc)
- regen highlight.js: `curl -sL -o hljs
  https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.10.0/highlight.min.js`
  then base64-chunk into `HighlightJSSource.swift` (sha256 pinned in file
  header; engine version pinned by test). License: BSD-3-Clause, banner
  preserved in the embedded bytes.

## Live rule

No live verification, zero prod footprint: shot `--show-code` (demo)
only, no live launches, no sends. Own shot PIDs only, all terminated.
Residual: wire `<p>`-wrap (Rust, out of scope) still collapses whitespace
in third-party clients — follow-up lane: emit `<pre>` for fenced blocks
in `send_message_with_client`.
