# Diet Teams

Native macOS client for Microsoft Teams: chat list, conversation, live
updates, calls. A SwiftUI app over a Rust core (`ostmac-core` FFI staticlib)
built on vendored [`ost`](https://github.com/eisbaw/ost). Runs fully offline
in `--demo` with canned data; sign in via device code or browser to go live.

![Diet Teams main window (demo mode)](docs/shots/om-reskin-chrome-demo.png)
![Teams channel (demo mode)](docs/shots/om-reskin-teams-channel.png)
![Device-code sign-in (demo placeholder)](docs/shots/om-reskin-chrome-auth-code.png)

## Features

Chat & conversation
: Sidebar (Chats / Teams / Reminders, pinned Mentions/Notifications) +
  conversation with Chat / Shared / Notes tabs, live Trouter feed, paged
  history, ⌘K jump palette, filters.
: Send, edit, delete, quote replies, emoji reactions, forward/copy/save,
  @-mention picker, rich rendering (mentions, code, inline images, bot
  posts, link previews), read receipts, typing indicators.
: Shared files (list/upload/download) + composer attachments; GIF picker
  (bring-your-own Tenor key).

Teams, meetings, reminders, notes
: Teams/channels browser; upcoming meetings + join-string parsing; To Do
  lists/tasks; OneNote notebooks/sections/pages read + paragraph append.

Calls
: Signaling (place/accept/end, echo-bot test), live A/V banner,
  mic/speaker/camera panel with probes, recent call history.

Notifications & presence
: Native banners with rules, quiet hours, @me/@team mention alerts,
  per-chat mutes; own + per-user presence.

Auth & session
: Device-code + browser (PKCE capture) sign-in, 13-state auth gate,
  refresh/expiry handling, persisted on-disk session.

Extras
: AI thread catch-up (OpenCode CLI or bring-your-own key, kept in the
  macOS keychain), diagnostics/health windows, MCP server (`ostmac-mcp`,
  see `docs/mcp.md`).

## Requirements

- macOS 14+, Xcode command line tools (`swift`, `xcodebuild`), Rust (`cargo`)

## Build / install / run

```sh
./scripts/test.sh        # rust tests + swift tests (builds rust first)
./scripts/build-rust.sh  # vendored ost + ostmac-core staticlib (release)
./scripts/build-app.sh   # Diet Teams.app in swift/.build/release
open "swift/.build/release/Diet Teams.app"
open "swift/.build/release/Diet Teams.app" --args --demo  # offline canned data
./scripts/package.sh [--install]  # signed release tmp/Diet Teams.app (+ /Applications)
./scripts/make-dmg.sh    # versioned installer in tmp/
./scripts/install.sh     # copy the release app to /Applications
```

Signing: `CODESIGN_IDENTITY` wins; else the first Apple Development
identity; else ad-hoc (mic/camera grants won't stick across rebuilds).

## Usage

- Try offline first: `--demo` (also `--demo-rich`, `--demo-reactions`,
  `--demo-botposts`, `--chat <id>`).
- Sign in from the app: device code (copy code / open browser) or
  browser sign-in; the session persists across launches. Settings shows
  the account row plus token/probe diagnostics.
- `ostmac-mcp` exposes chats to MCP clients (Claude Desktop) — see
  `docs/mcp.md`. It reuses the app's session; sign in once in the app.

## Architecture

- `swift/` — SPM package: `OstMac` (the app), `OstMacCore` (state +
  views), `OstMacChatList` (sidebar), `DietDesign` (design system),
  `OstMacMCP` + `ostmac-mcp` executable, `COstMac` (C header).
- `rust/ostmac-core/` — FFI `staticlib`: ~80-function C ABI, JSON over
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
