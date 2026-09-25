# Better Teams

Native macOS client for Microsoft Teams: chat list, conversation, live
updates, calls. A SwiftUI app over a Rust core (`ostmac-core` FFI staticlib)
built on vendored [`ost`](https://github.com/eisbaw/ost). Runs fully offline
in `--demo` with canned data; sign in via device code or browser to go live.

![Better Teams main window (demo mode)](docs/shots/om-reskin-chrome-demo.png)
![Teams channel (demo mode)](docs/shots/om-reskin-teams-channel.png)
![Meeting transcripts browser (demo mode)](docs/shots/om-better-transcripts.png)
<img src="docs/shots/om-reskin-chrome-auth-code.png" alt="Device-code sign-in (demo placeholder)" width="440">
<img src="docs/shots/om-better-settings-keywords.png" alt="Settings Keyword alerts section (demo seed)" width="440">

## Features

Ten headline features:

1. Native macOS app — SwiftUI over a Rust core, runs fully offline
   in `--demo` with canned data.
2. Chat sidebar — Chats / Teams / Reminders, pins, chat folders with
   auto-rules, filters, ⌘K search palette (chats, messages, files, people).
3. Full messaging — send, edit, delete, quote replies, emoji
   reactions, scheduled send + pending queue, per-chat snooze.
4. Rich conversation — mentions, code, inline images, bot posts,
   adaptive cards, link previews, read receipts, typing indicators.
5. Teams & channels browser — join/create team, create channel,
   channel detail + tabs, team roster.
6. Meetings — upcoming list, join parsing + lobby, recordings browser
   + playback, transcripts browser (turns + matching recording).
7. Calls — place/accept/end, live A/V banner, mic/speaker/camera
   panel, screen sharing, echo-bot test, call history.
8. Native notifications — banners with rules, quiet hours, @me/@team
   and keyword alerts, per-chat levels, presence.
9. AI thread catch-up — OpenCode CLI, on-device Apple Intelligence,
   or bring-your-own key (macOS keychain).
10. Easy sign-in — device code or browser (PKCE), multi-account
    switcher, persisted session.

Everything else, by area:

Chat & conversation
: Sidebar extras: pinned Mentions/Notifications, user chat pins,
  mark-unread, hide, leave/block; conversation with Chat / Shared /
  Notes tabs, live Trouter feed, paged history.
: Composer extras: forward/copy/save, pinned messages, @-mention
  picker; GIF picker (bring-your-own Klipy key, kept in the macOS
  keychain).
: Shared files: list/upload/download, folders + drill-in, share
  links, versions, move/copy/rename/delete, resumable big uploads,
  drag-drop + QuickLook, sort/filter, save-as; composer attachments.

Productivity
: To Do lists/tasks; OneNote notebooks/sections/pages read +
  paragraph append.
: Offline message archive (compressed export + local search index).

Session, diagnostics, integration
: 13-state auth gate, per-profile tokens, refresh/expiry handling.
: Diagnostics/health windows; MCP server (`ostmac-mcp`, see
  `docs/mcp.md`) reusing the app's session.

## Requirements

- macOS 14+, Xcode command line tools (`swift`, `xcodebuild`), Rust (`cargo`)

## Build / install / run

```sh
./scripts/test.sh        # rust tests + swift tests (builds rust first)
./scripts/build-rust.sh  # vendored ost + ostmac-core staticlib (release)
./scripts/build-app.sh   # Better Teams.app in swift/.build/release
open "swift/.build/release/Better Teams.app"
open "swift/.build/release/Better Teams.app" --args --demo  # offline canned data
./scripts/package.sh [--install]  # signed release tmp/Better Teams.app (+ /Applications)
./scripts/make-dmg.sh    # versioned installer in tmp/
./scripts/install.sh     # copy the release app to /Applications
```

Signing: `CODESIGN_IDENTITY` wins; else the first Apple Development
identity; else ad-hoc (mic/camera grants won't stick across rebuilds).

## Usage

- Try offline first: `--demo` (also `--demo-rich`, `--demo-reactions`,
  `--demo-botposts`, `--demo-showcase`, `--chat <id>`).
- Sign in from the app: device code (copy code / open browser) or
  browser sign-in; the session persists across launches. Settings shows
  the account row plus token/probe diagnostics.
- `ostmac-mcp` exposes chats to MCP clients (Claude Desktop) — see
  `docs/mcp.md`. It reuses the app's session; sign in once in the app.

## Architecture

- `swift/` — SPM package: `OstMac` (the app), `OstMacCore` (state +
  views), `OstMacChatList` (sidebar), `DietDesign` (design system),
  `OstMacMCP` + `ostmac-mcp` executable, `DietShowcase` (design-system
  demo), `COstMac` (C header).
- `rust/ostmac-core/` — FFI `staticlib`: ~100-function C ABI, JSON over
  the boundary, every string freed with `ostmac_free`.
- `rust/ost/` — vendored upstream `ost` (built as a lib) plus our
  documented patch stack (`OSTMAC-PATCHES.md`, tagged `[minor]`/`[major]`).
- `scripts/` — `build-rust.sh`, `build-app.sh`, `package.sh`,
  `make-dmg.sh`, `install.sh`, `make-icon.sh`, `test.sh`.
- `docs/shots/` — demo-mode screenshots (all sanitized, no live data).

Rust builds first; Swift links the staticlib. JSON keeps the FFI
boundary version-tolerant.

## Testing

`./scripts/test.sh` runs ost unit tests, ostmac-core tests, a release
core build, then the Swift suites (`OstMacCoreTests`, `OstMacMCPTests`,
`DietDesignTests`).

## Upstream & credits

Teams protocol core: [eisbaw/ost](https://github.com/eisbaw/ost) (Open
Source Teams client, Rust) — thank you. It is vendored under `rust/ost`
so the app builds on macOS and exposes a library surface; every local
change is a documented patch in `rust/ost/OSTMAC-PATCHES.md`.

## Contributing

PRs welcome. Run `./scripts/test.sh` first, and keep screenshots
demo-mode only (`--demo` flags) — no live chats, names, or tokens in
commits.

## License

MIT — see [LICENSE](LICENSE).
