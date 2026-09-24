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

// Browser-capture fallback start (auth-code + PKCE, no network):
// {ok, session, authorize_url, redirect_uri, expires_in}.
// Load authorize_url in a webview; the redirect_uri hit carries ?code&state.
// Caller frees.
char *ostmac_authcode_start(void);

// Browser-capture complete: session + intercepted callback URL (or raw
// query). Verifies state, exchanges the code, saves tokens:
// {ok, status:"complete", tokens} or {ok:false}. Parse/state failures
// keep the session (retryable); success drops it. Caller frees.
char *ostmac_authcode_complete(const char *session, const char *callback);

// Drop one pending browser session: {ok, cancelled}. Caller frees.
char *ostmac_authcode_cancel(const char *session);

// Current-user JSON (Graph /me): {ok,id,display_name,mail?}.
// Requires sign-in. Core caches after the first call; sign-out clears.
// Caller frees.
char *ostmac_whoami(void);

// Chat list JSON (requires sign-in). Caller frees.
char *ostmac_chats(int limit);

// Joined teams + channels JSON (requires sign-in). Caller frees.
char *ostmac_teams(void);

// Create one standard channel in a team (Graph POST, requires sign-in):
// {ok,channel:{id,name}}. description may be NULL (no description).
// Caller frees.
char *ostmac_channel_create(
    const char *team_id, const char *name, const char *description);

// Join one team by id (self-enroll): {ok, team_id}. Caller frees.
char *ostmac_team_join(const char *team_id);

// One channel's pinned tabs JSON, read-only: {ok, channel_id, tabs}. Caller frees.
char *ostmac_tabs(const char *channel_id);

// One team's roster JSON: {ok, team_id, members:[{id, display_name,
// user_id?, email?, roles, is_owner}]} (requires sign-in). Caller frees.
char *ostmac_team_members(const char *team_id);

// Add one user (id or UPN) to a team; owner nonzero grants the owner
// role. Returns {ok, member}. Caller frees.
char *ostmac_team_member_add(const char *team_id, const char *user, int owner);

// Remove one membership id from a team. Returns {ok, team_id,
// member_id}. Caller frees.
char *ostmac_team_member_remove(const char *team_id, const char *member_id);

// Message history JSON for one chat (requires sign-in). Caller frees.
char *ostmac_messages(const char *chat_id, int limit);

// Older history page: page_token is the previous response's opaque cursor.
// Caller frees.
char *ostmac_messages_page(const char *chat_id, const char *page_token, int limit);

// Post one message to a chat. Caller frees.
char *ostmac_send(const char *chat_id, const char *text);

// Add one emoji reaction to a message. Caller frees.
char *ostmac_react(const char *chat_id, const char *message_id, const char *emoji);

// Remove one emoji reaction from a message. Caller frees.
char *ostmac_react_remove(const char *chat_id, const char *message_id, const char *emoji);

// Post one quote reply to a chat message: parent_id is the quoted
// message id, parent_sender/parent_text attribute the quote block
// (blank sender/text fall back to "?"/parent id in core).
// Returns {ok, chat_id}. Caller frees.
char *ostmac_reply(
    const char *chat_id, const char *parent_id,
    const char *parent_sender, const char *parent_text,
    const char *text);

// Edit one own message: {ok, chat_id, message_id}. Caller frees.
char *ostmac_edit(const char *chat_id, const char *message_id, const char *text);

// Delete one own message: {ok, chat_id, message_id}. Caller frees.
char *ostmac_delete(const char *chat_id, const char *message_id);

// Leave one group chat (remove self from the thread roster):
// {ok, chat_id}. Caller frees.
char *ostmac_leave(const char *chat_id);

// Mark one conversation read up to a message (consumption horizon PUT):
// {ok, chat_id, message_id}. Caller frees.
char *ostmac_mark_read(const char *chat_id, const char *message_id);

// Peer read positions for one thread:
// {ok, thread_id, receipts:[{user, message_id, horizon}]}. Caller frees.
char *ostmac_receipts(const char *thread_id);

// Fetch one inline-image URL: {ok, data_base64, content_type?}.
// Microsoft media hosts attach the Skype token; public hosts fetch
// without auth. https only. Requires sign-in for auth'd hosts.
// Caller frees.
char *ostmac_media_fetch(const char *url);

// Shared files JSON for one chat/channel (requires sign-in). Caller frees.
char *ostmac_files(const char *chat_id, int limit);

// Upload a local file (<4 MB) to a chat/channel + post reference message.
// Returns {ok, file}. Caller frees.
char *ostmac_files_upload(const char *chat_id, const char *path);

// Download one driveItem's content to dest path.
// Returns {ok, path, bytes}. Caller frees.
char *ostmac_files_download(const char *drive_id, const char *item_id, const char *dest);

// Rename one driveItem (PATCH name). Returns {ok, file}. Caller frees.
char *ostmac_files_rename(const char *drive_id, const char *item_id, const char *new_name);

// Move one driveItem to another folder (same drive). Returns {ok, file}.
// Caller frees.
char *ostmac_files_move(const char *drive_id, const char *item_id, const char *dest_folder_id);

// Copy one driveItem to another folder (same drive, async server-side).
// new_name may be NULL to keep the source name. Returns {ok, monitor}.
// Caller frees.
char *ostmac_files_copy(const char *drive_id, const char *item_id, const char *dest_folder_id, const char *new_name);

// Delete one driveItem. Returns {ok, id}. Caller frees.
char *ostmac_files_delete(const char *drive_id, const char *item_id);

// To Do lists JSON (requires sign-in): {ok,lists:[{id,name,wellknown?}]}.
// Caller frees.
char *ostmac_reminders(void);

// Tasks for one To Do list: {ok,list_id,tasks:[{id,title,status,
// importance,due?,reminder?,completed}]}. Caller frees.
char *ostmac_reminder_tasks(const char *list_id, int limit);

// Create one task in a list: {ok,task}. Caller frees.
char *ostmac_reminder_add(const char *list_id, const char *title);

// Mark one task completed: {ok,task}. Caller frees.
char *ostmac_reminder_done(const char *list_id, const char *task_id);

// Upcoming meetings JSON (Graph calendarView, next 7 days, requires
// sign-in): {ok,meetings:[{id,subject,start?,end?,join_url?,
// organizer?,is_online}]}. Caller frees.
char *ostmac_meetings(int limit);

// Classify a pasted join string (pure, no network, no sign-in):
// {ok,target:{kind,thread_id?,meeting_id?,url}}. kind is
// thread|meeting-id|url|unknown. Caller frees.
char *ostmac_meeting_join_parse(const char *raw);

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

// Resolve a Teams MRI (8:orgid:<aad-oid>) to a Graph user:
// {ok,id,email?,display_name}. {ok:false,error:"not_found"} for unknown
// users (permanent). Caller frees. Hits network.
char *ostmac_resolve_mri(const char *mri);

// OneNote notebooks JSON: {ok,notebooks:[{id,name}]}. group_id NULL/empty
// reads the user's own; otherwise the M365 group (team) notebooks.
// Requires sign-in. Caller frees. Hits network.
char *ostmac_notes(const char *group_id);

// One notebook's sections, each with pages:
// {ok,sections:[{id,name,pages:[{id,title,updated?}]}]}. Caller frees.
char *ostmac_note_sections(const char *notebook_id, const char *group_id);

// One page's HTML content: {ok,id,title,html}. Caller frees.
char *ostmac_note_page(const char *page_id, const char *group_id);

// Append one plain-text paragraph to a page: {ok,id}. Caller frees.
char *ostmac_note_append(const char *page_id, const char *text, const char *group_id);

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

// Place an outgoing call with live media attached on acceptance:
// {ok,placed,accepted,live_media,call}. Caller frees.
char *ostmac_call_place_live(const char *thread_id, int timeout_secs);

// Place the echo-bot test call with live media. Same envelope as
// ostmac_call_place_live. Caller frees.
char *ostmac_call_echo_live(int timeout_secs);

// Accept the ringing incoming call with live media:
// {ok,accepted,media_answered,live_media,call}. Caller frees.
char *ostmac_call_accept_live(void);

// Live media engine stats:
// {ok, media:{running,audio_sent,audio_recv,video_sent,video_recv,
// send_queued,send_dropped,recv_pending,recv_dropped,
// ice_audio,ice_video,error?,started_at}}. Caller frees. No network.
char *ostmac_call_media(void);

// Stop the live media engine: {ok, media}. Caller frees.
char *ostmac_call_media_stop(void);

// Mute/unmute the live call mic (nonzero = muted), sticky across calls:
// {ok, muted}. Stored when idle, honored by the next call. Caller frees.
// No network.
char *ostmac_call_mute(int muted);

// Select the call speaker route (NULL/"" = system default): {ok, speaker}.
// Stored always; reroutes a live call without dropping the current device
// on failure. Caller frees. No network.
char *ostmac_call_speaker(const char *name);

// Push one send-side access unit: JSON array of base64 NALs (no start
// codes). Over-cap pushes drop the oldest unit. Returns {ok, queued}.
// Caller frees.
char *ostmac_video_send_push(const char *nals_json);

// Drain the newest incoming access unit:
// {ok, au:{nals:[b64..]}|null, dropped}. Caller frees.
char *ostmac_video_poll_incoming(void);

// Offline loopback: run queued send units through packetize -> SRTP ->
// depacketize -> incoming queue (no network/auth/hardware).
// {ok, units, packets, aus, nals}. Caller frees.
char *ostmac_live_loopback(void);

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
