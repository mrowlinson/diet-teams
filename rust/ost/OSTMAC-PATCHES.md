# OstMac patches on vendored ost

Upstream ref: `TeamsNotifier/tmp/refs/eisbaw_ost` (read-only). This copy is
vendored so the spike can build on macOS and expose a library surface.

1. `src/calling/sdp_compress.rs` — **build fix (upstream bug)**.
   `SDP_DICTIONARY: &[u8; 20623]` but `sdp_dictionary.bin` is 20476 bytes →
   E0308. Changed to unsized `&[u8]`, dropped two `.as_slice()` calls.
2. `src/tui/app.rs` — **stay open unsigned**.
   Unsigned, the backend task exits → channel closes → `run_app` broke the
   loop → exit 0 with no UI. Now the loop survives backend death (guarded
   `select!` branch) so layout + auth error stay visible and navigable.
3. `src/event_hub.rs` (new) + 1 line in `src/trouter/mod.rs` + `mod` in
   `src/main.rs` — **Trouter event channel**. Frame handler publishes event
   JSON to an in-process queue; embedders drain via `event_hub::drain`.
4. `Cargo.toml` (`[lib]` name `ost` + `[[bin]]`) + `src/lib.rs` (new) —
   **library surface**. Same modules as the binary, `pub`, so `ostmac-core`
   reuses auth/api/trouter without forking. Binary untouched.
5. `src/api/chat.rs` — **message ids for embedders (om-conv lane)**.
   `MessageInfo` gains `id` (server `NativeMessage.id`, synthetic
   `timestamp@sender` fallback) so Swift can match realtime edits in place.
   TUI mapping is field-wise reads; only the constructor here changed.
6. `src/api/chat.rs` `read_messages_data` — **skip media payloads (om-conv)**.
   `RichText/Media_*` stripped to "TitlePlay" fragments (CallRecording) or
   raw JSON (CallTranscript); now skipped. Empty display names fall back to
   `"?"` like missing ones. TUI list benefits identically.
