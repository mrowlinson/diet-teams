# OstMac patches on vendored ost

Upstream ref: `TeamsNotifier/tmp/refs/eisbaw_ost` (read-only). This copy is
vendored so the spike can build on macOS and expose a library surface.

Tags: [minor] = bugfix/small improvement, no API/architecture change.
[major] = new modules, lib surface, platform code, or behavior change
needing maintainer buy-in. Minor PRs stand alone; majors are separate PRs.

1. [minor] `src/calling/sdp_compress.rs` — **build fix (upstream bug)**.
   `SDP_DICTIONARY: &[u8; 20623]` but `sdp_dictionary.bin` is 20476 bytes →
   E0308. Changed to unsized `&[u8]`, dropped two `.as_slice()` calls.
2. [minor] `src/tui/app.rs` — **stay open unsigned**.
   Unsigned, the backend task exits → channel closes → `run_app` broke the
   loop → exit 0 with no UI. Now the loop survives backend death (guarded
   `select!` branch) so layout + auth error stay visible and navigable.
3. [major] `src/event_hub.rs` (new) + 1 line in `src/trouter/mod.rs` + `mod` in
   `src/main.rs` — **Trouter event channel**. Frame handler publishes event
   JSON to an in-process queue; embedders drain via `event_hub::drain`.
4. [major] `Cargo.toml` (`[lib]` name `ost` + `[[bin]]`) + `src/lib.rs` (new) —
   **library surface**. Same modules as the binary, `pub`, so `ostmac-core`
   reuses auth/api/trouter without forking. Binary untouched.
5. [minor] `src/api/chat.rs` — **message ids for embedders (om-conv lane)**.
   `MessageInfo` gains `id` (server `NativeMessage.id`, synthetic
   `timestamp@sender` fallback) so Swift can match realtime edits in place.
   TUI mapping is field-wise reads; only the constructor here changed.
6. [minor] `src/api/chat.rs` `read_messages_data` — **skip media payloads (om-conv)**.
   `RichText/Media_*` stripped to "TitlePlay" fragments (CallRecording) or
   raw JSON (CallTranscript); now skipped. Empty display names fall back to
   `"?"` like missing ones. TUI list benefits identically.
7. [minor] `src/api/chat.rs` — **history paging + raw HTML (om-convrich lane)**.
   New `read_messages_page` follows `_metadata.backwardLink` for older pages
   (live-verified: no overlap, chainable; `startTime=` alone is ignored by
   the server); `pageSize` rewritten per call. `MessagesPage`/`read_messages_page`
   re-exported in `src/api/mod.rs`. `MessageInfo` gains `raw` (unstripped
   HTML for mention/code mining). `read_messages_data` keeps its signature
   (delegates, newest page). TUI untouched.
8. [minor] `src/calling/audio.rs` — **audio test utils + device pickers
   (om-av, extended om-av-polish)**. `audio_probe()`, `mic_test_report(seconds,
   vu)` (`mic_test()` delegates), `play_tone(msecs)`; named devices via
   `start_on`, `input/output_device_names`, `default_input/output_name`,
   `mic_test_report_on`, `play_tone_on`; metering via `frame_db`,
   `mic_level_sample`. Robustness: serialized CoreAudio setup lock, bounded
   waits (`poll_started` replaces fixed sleep), unknown names fail fast.
9. [minor] `src/trouter/mod.rs` — **`TEAMS_MANUAL_CALLS` gate**.
   Set to take call accept/end in embedding UI; the invitation is still
   published to `event_hub` either way. Unset = auto-answer as before.
10. [minor] `src/calling/recording.rs` — **`TEAMS_DEBUG_DUMP` gate**.
    Full add-recorder response was written to `/tmp` unconditionally;
    now only when the env var is set. CLI sets it for protocol analysis.
11. [major] `src/calling/macav.rs` (new, 514 lines) + `pub mod macav` —
    **macOS A/V bridge, Rust side (om-av lane)**. I420 conversion, camera/
    remote frame slots fed by Swift AVCapture, tone echo check, black-frame
    NAL source, offline call dry-run (tone→PCMU→RTP→SRTP round-trip plus
    black IDR packetize/depacketize). No network, no auth, unit-testable.
12. [minor] `src/api/media.rs` (new) + `media_get` in `src/api/client.rs` +
    `has_image` keep in `src/api/chat.rs` (om-richmedia lane) — **inline
    media fetch**. `fetch_media_data` downloads chat `<img>` bytes (15MB
    cap, https-only); `needs_auth` keeps the Skype token on Microsoft
    hosts, public URLs fetch bare. Image-only bubbles (empty stripped
    text) survive the filter. Re-exported in `src/api/mod.rs`.
13. `src/tui/` deleted + `Tui` subcommand + `mod tui` wiring (`main.rs`,
    `lib.rs`) + `ratatui`/`crossterm`/`tokio-stream`/`unicode-width` deps —
    [major][LOCAL-ONLY, do not upstream] **drop TUI from our vendored copy**.
    Diet Teams (SwiftUI) replaces the UI; the TUI is eisbaw's product, we
    keep our copy lean (CLI debug surface + `ostmac-core` lib only). All CLI
    subcommands (`chats`/`read`/`send`/`call-test`/etc) unchanged. 8 TUI unit
    tests drop with the module; zero failures expected elsewhere.
14. `src/api/files.rs` (new) + `src/api/client.rs` + `src/api/mod.rs` +
    `src/main.rs` — **chat shared files via Graph driveItems (om-shared lane)**.
    `SharedFile`/`list_chat_files_data`/`download_file_data`/`upload_file_data`
    re-exported in `src/api/mod.rs`. Chats: Graph `/me/chats/{id}/messages`
    `reference` attachments resolved via `/shares/{u!b64}/driveItem` (deduped
    by item id, folders skipped); channels: team scan + `filesFolder` +
    `/drives/{d}/items/{i}/children`. CLI: `files`, `files-download`,
    `files-upload`. `client.rs` gains `graph_put_bytes` (drive PUT). Upload is
    small-file PUT only (<4 MB, chat folder "Microsoft Teams Chat Files") +
    `reference` message post (attachment id = GUID from driveItem eTag,
    contentUrl = webDavUrl/webUrl). No auth scope change: existing Graph token
    (`/.default`) already carries Files.Read/Write. Unit tests: share-id
    round-trip, segment encoding, eTag GUID scan, children/message parsing,
    attachment preference.

15. `src/api/todo.rs` (new) + `src/api/mod.rs` + `src/api/client.rs` +
    `src/main.rs` — **Microsoft To Do lists/tasks (om-remind lane)**.
    Graph `/me/todo/lists`, `/lists/{id}/tasks` (GET), create (POST),
    complete (PATCH `status: completed`). `TodoListInfo`/`TodoTaskInfo`
    + `*_data` fns re-exported; CLI `todo` (bare lists, `--list`,
    `--add/--to`, `--done/--to`). `client.rs` gains generic `graph_patch`.
    Auth: existing Graph token, NO scope widening (Teams client id already
    consents Tasks.ReadWrite; 403 surfaces as the call detail). Ids breaking
    the path (`/`, `?`, `#`, whitespace) rejected pre-network. TUI untouched.

## Upstream PRs (2026-09-22, base 0892144; main red on sdp E0308 until #5)

Minor (standalone modulo #5-first; merge in any order after):
- (a) bugfixes sdp+tui: https://github.com/eisbaw/ost/pull/5
- (b) chat API ids+media+paging+fetch: https://github.com/eisbaw/ost/pull/6
- (c) audio test utils: https://github.com/eisbaw/ost/pull/7
- (d) debug gates MANUAL_CALLS+DEBUG_DUMP: https://github.com/eisbaw/ost/pull/8
Major (need maintainer buy-in):
- (e) [major] macav module: https://github.com/eisbaw/ost/pull/9
- (f) [major] event_hub+lib surface: https://github.com/eisbaw/ost/pull/10
