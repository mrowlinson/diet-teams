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

// Message history JSON for one chat (requires sign-in). Caller frees.
char *ostmac_messages(const char *chat_id, int limit);

// Older history page: page_token is the previous response's opaque cursor.
// Caller frees.
char *ostmac_messages_page(const char *chat_id, const char *page_token, int limit);

// Post one message to a chat. Caller frees.
char *ostmac_send(const char *chat_id, const char *text);

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
