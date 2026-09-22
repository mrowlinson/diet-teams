// ostmac_core.h — C ABI of the ostmac-core Rust staticlib.
// JSON over the boundary; every returned string freed with ostmac_free.
#ifndef OSTMAC_CORE_H
#define OSTMAC_CORE_H

// Static version string ("1.0.0"). Never freed.
const char *ostmac_version(void);

// 0 = core usable (tokio runtime builds). No network.
int ostmac_init(void);

// Auth status JSON. Caller frees.
char *ostmac_status(void);

// Device-code start JSON: session, verification_uri, user_code, message.
// Caller frees. Hits network.
char *ostmac_device_start(void);

// Single poll for session (NUL-terminated C string).
// pending | complete (+tokens saved) | {ok:false}. Caller frees.
char *ostmac_device_poll(const char *session);

// Current-user JSON (Graph /me): {ok,id,display_name,mail?}.
// Requires sign-in. Core caches after the first call; sign-out clears.
// Caller frees.
char *ostmac_whoami(void);

// Chat list JSON (requires sign-in). Caller frees.
char *ostmac_chats(int limit);

// Joined teams + channels JSON (requires sign-in). Caller frees.
char *ostmac_teams(void);

// Message history JSON for one chat (requires sign-in). Caller frees.
char *ostmac_messages(const char *chat_id, int limit);

// Older history page: page_token is the previous response's opaque cursor.
// Caller frees.
char *ostmac_messages_page(const char *chat_id, const char *page_token, int limit);

// Post one message to a chat. Caller frees.
char *ostmac_send(const char *chat_id, const char *text);

// Fetch one inline-image URL: {ok, data_base64, content_type?}.
// Microsoft media hosts attach the Skype token; public hosts fetch
// without auth. https only. Requires sign-in for auth'd hosts.
// Caller frees.
char *ostmac_media_fetch(const char *url);

// Start background Trouter push: 0 ok, -1 running, -2 no auth, -3 rt fail.
int ostmac_trouter_start(void);

// Drain queued Trouter events as JSON. Caller frees.
char *ostmac_trouter_poll(void);

// Drain queued Trouter events as typed realtime messages:
// {ok, messages:[{chat_id,id,sender,text,time,is_edit,edited_id?}],
// resync, skipped}. resync=true means a trouter.message_loss frame arrived:
// the UI must re-fetch visible conversations (push had a gap; the socket is
// fine, no reconnect needed). Drains the same queue as ostmac_trouter_poll —
// use one consumer. Caller frees.
char *ostmac_trouter_poll_typed(void);

// Stop background Trouter: 0 stopped, -1 idle.
int ostmac_trouter_stop(void);

// Refresh AAD + derived tokens via the stored refresh token:
// {ok, refreshed, tokens?}. refreshed=false means no refresh token stored
// (run device flow). Caller frees. Hits network when a refresh token exists.
char *ostmac_refresh(void);

// Clear all stored tokens (sign out); drops pending device sessions.
// {ok:true} or {ok:false}. Caller frees. No network.
char *ostmac_sign_out(void);

// Own presence JSON (Graph /me/presence): {ok,availability,activity}.
// Requires sign-in. Caller frees. Hits network.
char *ostmac_presence(void);

// Set own preferred presence. status is one of (case-insensitive):
// available, busy, dnd (donotdisturb), away, offline.
// Returns the applied {ok,availability,activity}. Caller frees.
char *ostmac_presence_set(const char *status);

// One other user's presence JSON (Entra ID or UPN):
// {ok,id,availability,activity}. Caller frees. Hits network.
char *ostmac_presence_user(const char *user_id);

// Current call slot JSON: {ok, call:{id,dir,peer,peer_name,thread,
// state,controller?,started_at,detail?}|null}. Caller frees. No network.
char *ostmac_call_status(void);

// Place an outgoing call to a thread id (1:1 or channel), signaling
// only. Blocks up to timeout_secs (clamped 5..120) waiting for the
// answer: {ok,placed,accepted,rejection?,call}. Caller frees.
char *ostmac_call_place(const char *thread_id, int timeout_secs);

// Place the echo-bot test call, signaling only. Same envelope as
// ostmac_call_place. Caller frees.
char *ostmac_call_echo(int timeout_secs);

// Accept the ringing incoming call:
// {ok,accepted,media_answered,call}. Caller frees.
char *ostmac_call_accept(void);

// End/decline the active call: {ok,ended,call}. Caller frees.
char *ostmac_call_end(void);

// Inject the recorder bot into the connected outgoing call:
// {ok,injected,response_bytes}. Caller frees.
char *ostmac_call_record_inject(void);

// A/V capability map (static, no hardware). Caller frees.
char *ostmac_av_info(void);

// Mic/speaker availability probe (cpal open+close, fast). Caller frees.
char *ostmac_mic_probe(void);

// Capture `seconds` (1-10, default 3) of mic + play back:
// {ok, frames, seconds, peak_db, played_back} or {ok:false, error:"no_input"}.
// Caller frees. Blocks for the capture duration.
char *ostmac_mic_test(int seconds);

// Play 1kHz tone for `msecs` (default 1000): {ok, frames} or
// {ok:false, error:"no_output"}. Caller frees. Blocks while playing.
char *ostmac_tone_play(int msecs);

// Deterministic tone echo self-check (no hardware). Caller frees.
char *ostmac_tone_check(void);

// Audio device display names + system defaults:
// {ok, inputs[], outputs[], default_input, default_output}. Caller frees.
char *ostmac_audio_devices(void);

// Named-device mic test (NULL/"" = default):
// {ok, frames, seconds, peak_db, played_back} or
// {ok:false, error:"no_input"|"unknown_device"}. Caller frees. Blocks.
char *ostmac_mic_test_on(int seconds, const char *input, const char *output);

// Named-device tone play (NULL/"" = default output).
// Caller frees. Blocks while playing.
char *ostmac_tone_play_on(int msecs, const char *output);

// Short mic level sample for a live meter:
// {ok, peak_db, has_input} (never errors; no device -> has_input=false).
// Caller frees. Blocks ~msecs + 100ms setup.
char *ostmac_mic_level(int msecs, const char *input);

// Begin a camera run (Swift AVCapture feeds frames). Caller frees.
char *ostmac_camera_begin(int width, int height, int fps);

// Push one camera frame: base64 pixels, fmt i420|nv12|bgra (420v|32bgra
// aliases). Convert failures count as drops. Returns stats JSON.
// Caller frees.
char *ostmac_camera_push(const char *b64, int width, int height, const char *fmt);

// Camera stats JSON. Caller frees.
char *ostmac_camera_stats(void);

// End the camera run. Caller frees.
char *ostmac_camera_end(void);

// Push one decoded remote I420 frame (base64) for display. Caller frees.
char *ostmac_video_push_remote(const char *b64, int width, int height);

// Drain latest remote frame: {ok, frame:{width,height,data}|null}.
// Caller frees.
char *ostmac_video_poll_remote(void);

// Black 176x144 IDR access unit as base64 NALs (VideoToolbox target).
// Caller frees.
char *ostmac_av_black_iframe(void);

// Offline call pipeline: SRTP loopback + H.264 packetize round-trip
// (no network/auth/hardware). Caller frees.
char *ostmac_call_dry_run(void);

// Free a string from any ostmac_* call. Null-safe.
void ostmac_free(char *s);

#endif
