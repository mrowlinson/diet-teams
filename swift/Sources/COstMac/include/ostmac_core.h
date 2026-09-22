// ostmac_core.h — C ABI of the ostmac-core Rust staticlib.
// JSON over the boundary; every returned string freed with ostmac_free.
#ifndef OSTMAC_CORE_H
#define OSTMAC_CORE_H

// Static version string ("0.1.0"). Never freed.
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

// Chat list JSON (requires sign-in). Caller frees.
char *ostmac_chats(int limit);

// Start background Trouter push: 0 ok, -1 running, -2 no auth, -3 rt fail.
int ostmac_trouter_start(void);

// Drain queued Trouter events as JSON. Caller frees.
char *ostmac_trouter_poll(void);

// Stop background Trouter: 0 stopped, -1 idle.
int ostmac_trouter_stop(void);

// Free a string from any ostmac_* call. Null-safe.
void ostmac_free(char *s);

#endif
