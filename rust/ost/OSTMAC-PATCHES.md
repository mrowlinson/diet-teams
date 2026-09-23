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

16. `src/api/notes.rs` (new) + `src/api/client.rs` (`graph_patch_raw`) +
    `src/main.rs` (`Notes` cmd) — **OneNote read + paragraph append
    (om-notes lane)**. `list_notebooks_data` (`/me` or `/groups/{id}` scoped),
    `list_notebook_sections_data` (sections with nested pages; failed pages
    fetch warns + empties, teams.rs parity), `read_note_page_data` (raw HTML,
    title scraped from `<title>`), `append_note_paragraph_data` (PATCH with
    hand-rolled multipart Commands, no new deps). CLI: `notes [--group]`,
    `--notebook` lists sections+pages, `--page` prints stripped text,
    `--page --append` appends then prints. Auth scopes unchanged: the
    existing Graph `/.default` exchange covers OneNote (delegated perms ride
    the first-party client); no new consent requested.

17. [minor] `src/api/chat.rs` + `src/api/client.rs` (`chat_delete`) +
    `src/api/mod.rs` + `src/main.rs` (`React` cmd) — **message reactions
    (om-reactions lane)**. Emoji↔type map (`REACTION_EMOJI`, the six Teams
    types), `reaction_add_url/body` + `reaction_remove_url` builders,
    `send/remove_reaction_with_client` (POST/DELETE
    `.../messages/{id}/reactions` with skypetoken auth, Graph-mirrored
    shape), `MessageInfo.reactions` grouped counts parsed from top-level
    or `properties.reactions` (unknown types dropped). CLI: `react --to
    --message-id <emoji> [--remove]`. NOT YET VERIFIED LIVE: the add/
    remove wire shape is best-effort (Graph resource layout over the
    native chat service); confirm with `react` against a signed-in box
    before upstreaming. Unit tests: emoji map, endpoint shapes, grouping
    order, nested/unknown/missing reaction payloads.
18. [minor] `src/api/chat.rs` + `src/api/mod.rs` + `src/main.rs` —
    **quote replies (om-replies lane)**. `MessageInfo` gains `reply_to`
    (parent id mined from the first `<quote guid>` block; `content` is the
    reply body only, `raw` keeps the full HTML). Pure helpers
    `reply_snippet` (one-line, 140 chars + `…`), `build_reply_html`
    (Skype-style `<quote author guid>` + `<p>` body, all fields escaped),
    `split_reply_quote` (malformed quotes keep content, never drop it),
    re-exported in `src/api/mod.rs`. Send path:
    `reply_message_with_client` posts `RichText/Html` with the quote block
    (official clients render it as a quote); `reply_message` resolves the
    parent from the newest history page for attribution. CLI: `send
    --reply-to <id>`; `read` marks replies `(reply to <id>)`. Unit tests:
    snippet collapse/truncate (incl. multibyte boundary), build→split
    round-trip with escaping, malformed-quote cases.
19. [minor] `src/api/chat.rs` — **chat names: mate resolve, system
    labels, spacing-aware strip (om-chatnames lane)**. `conversation_name`
    fallback is now topic → resolved 1:1 mate → last sender → system
    label, never the raw thread id (`48:notifications` → `Notifications`,
    else `[Direct message]`/`[Group chat]`/`[Meeting chat]`/`[Chat]`).
    1:1 mate names resolve via MRI: thread roster (`GET
    /v1/threads/{id}/members`, read-only) minus self (whoami OID suffix
    match) leaves the mate, attributed to the newest message carrying
    that MRI (`MessageInfo` gains `sender_mri`, parsed from the `from`
    user link). Best-effort: roster/history/whoami failures keep the
    sender/label fallback, never fail the list. `strip_html` is
    spacing-aware: block-tag boundaries yield one space (`</p><p>`
    no longer glues words), inline tags vanish silently, no
    leading/trailing space. Dup-name threads are real: live fetch shows
    distinct server threads sharing a display name (e.g. two 1:1s with
    one mate), not a client duplication — no dedup applied. Unit tests:
    strip boundaries, name fallback chain, MRI parse/match, roster
    shape. Live-verified 2026-09-23 (`chats`: labels applied, 1:1s
    mate-named).

19. [minor] `src/api/media.rs` + `src/api/client.rs` +
    `tests/imgfix_live_probe.rs` (new) — **live AMS fetch fix (om-imgfix
    lane)**. Inline images 401d: the ASM object-store family
    (`*.asm.skype.com`, `*.asyncgw.teams.microsoft.com`) authenticates
    with `Authorization: skype_token …`, not the chat-service scheme
    (`Authentication: skypetoken=` + `X-SkypeToken`), which is kept for
    chat-hosted views (`…msg.teams.microsoft.com…`). New pure
    `media::auth_headers` picks the scheme per host; `media_get`
    delegates transport to `media_fetch` so the mocked repro matrix
    (local TCP stub, no new deps) pins all three legs: ASM/chat header
    mapping, same-host 302 follow, 401 surfacing, non-image shape
    passthrough, 15 MB cap. `MediaBytes` gains `Debug`. Committed
    `#[ignore]`d live probe harvests one AMS `<img>` from newest pages
    then issues a single redirect-disabled GET with production headers
    (status/size/shape booleans only, bytes discarded). Verified: live
    probe pre-fix 401 on `us-api.asm.skype.com …/views/imgo`; matrix
    red→green on the mapping; app screenshots show loaded images.

19. [minor] `src/api/chat.rs` — **keep RSS/bot/card posts (om-botposts
    lane)**. `has_card_payload` (an `<attachment>` block or an O365 /
    Adaptive / MessageCard marker, case-insensitive) joins the empty-text
    keep rule next to `has_image`: card posts strip to `""` but are real
    messages — the embedder renders title+link rows from `raw`, or a
    placeholder when it cannot parse the payload — so history never
    silently drops them. CLI `read` prints `(card post)` for kept
    card-shaped empties instead of a blank line (image-only bubbles
    unchanged). Unit tests: attachment/marker detection incl. casing,
    plain/image/empty negatives.

19. [minor] `src/api/files.rs` — **scope-aware chat/channel routing
    (om-sharednotes lane)**. New `is_channel_id` (`@thread.tacv2` suffix;
    chats share the `19:` prefix but end `@thread.v2`): list tries the
    channel filesFolder path first for channel-shaped ids and the
    chat-messages path first otherwise, each keeping the other as fallback.
    Upload routes the same way, so chat uploads skip the team scan
    (joinedTeams + one channels call per team) and channel uploads fail fast
    with "no joined team contains channel" instead of mis-posting to the
    OneDrive chat folder. Unit test: tacv2 suffix cases.

## Upstream PRs (2026-09-22, base 0892144; main red on sdp E0308 until #5)

Minor (standalone modulo #5-first; merge in any order after):
- (a) bugfixes sdp+tui: https://github.com/eisbaw/ost/pull/5
- (b) chat API ids+media+paging+fetch: https://github.com/eisbaw/ost/pull/6
- (c) audio test utils: https://github.com/eisbaw/ost/pull/7
- (d) debug gates MANUAL_CALLS+DEBUG_DUMP: https://github.com/eisbaw/ost/pull/8
Major (need maintainer buy-in):
- (e) [major] macav module: https://github.com/eisbaw/ost/pull/9
- (f) [major] event_hub+lib surface: https://github.com/eisbaw/ost/pull/10
