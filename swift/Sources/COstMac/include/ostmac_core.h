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

// Free a string from any ostmac_* call. Null-safe.
void ostmac_free(char *s);

#endif
