//! ostmac-core: minimal embeddable surface over vendored `ost`.
//!
//! Exposes five capabilities to Swift (via C ABI, JSON over the FFI):
//! - auth: RFC 8628 device-code `start` (get URL+code) and single-shot `poll`
//! - chats: structured chat list (requires sign-in)
//! - messages: full history for one chat (requires sign-in)
//! - send: post one message to a chat (requires sign-in)
//! - trouter: background push connection with a polled event channel
//!
//! Dropped for now: TUI, audio/video, call media.

use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use ost::auth::{AuthConfig, TokenStore};
use ost::config::Config;
use serde_json::json;

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn err_json(code: &str, detail: impl std::fmt::Display) -> String {
    json!({"ok": false, "error": code, "detail": detail.to_string()}).to_string()
}

fn cstr_to_string(p: *const c_char) -> Result<String, String> {
    if p.is_null() {
        return Err("null pointer".to_string());
    }
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .map(|s| s.to_string())
        .map_err(|e| format!("invalid utf-8: {}", e))
}

fn string_to_c(s: String) -> *mut c_char {
    CString::new(s).map(|c| c.into_raw()).unwrap_or(std::ptr::null_mut())
}

fn rt() -> Result<tokio::runtime::Runtime, String> {
    tokio::runtime::Runtime::new().map_err(|e| format!("runtime: {}", e))
}

fn token_summary(cfg: &Config) -> serde_json::Value {
    let slot = |t: Option<ost::auth::StoredToken>| match t {
        Some(tok) if !tok.is_expired() => json!({"present": true, "expired": false}),
        Some(_) => json!({"present": true, "expired": true}),
        None => json!({"present": false, "expired": false}),
    };
    json!({
        "aad": slot(cfg.get_access_token()),
        "refresh_present": cfg.get_refresh_token().is_some(),
        "graph": slot(cfg.get_graph_token()),
        "ic3": slot(cfg.get_ic3_token()),
        "recorder": slot(cfg.get_recorder_token()),
        "skype": slot(cfg.get_skype_token()),
        "region_gtms_present": cfg.region_gtms.is_some(),
    })
}

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

/// JSON auth status. Pure read of the on-disk config, no network.
pub fn status_json() -> String {
    match Config::load() {
        Ok(cfg) => {
            let summary = token_summary(&cfg);
            let signed_in = summary["aad"]["expired"] == false
                && summary["aad"]["present"] == true;
            json!({"ok": true, "signed_in": signed_in, "tokens": summary}).to_string()
        }
        Err(e) => err_json("config_load", e),
    }
}

// ---------------------------------------------------------------------------
// Device-code auth (direct HTTPS, no oauth2 crate: single-shot poll control)
// ---------------------------------------------------------------------------

struct PendingSession {
    device_code: String,
    token_url: String,
    client_id: String,
    created_at: u64,
    expires_in: u64,
    interval: u64,
}

fn sessions() -> &'static Mutex<HashMap<String, PendingSession>> {
    static S: OnceLock<Mutex<HashMap<String, PendingSession>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(HashMap::new()))
}

static SESSION_COUNTER: AtomicU64 = AtomicU64::new(1);

fn new_session_id() -> String {
    let n = SESSION_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("dc-{}-{}", now_secs(), n)
}

fn lock_sessions() -> std::sync::MutexGuard<'static, HashMap<String, PendingSession>> {
    sessions().lock().unwrap_or_else(|e| e.into_inner())
}

/// Start device-code flow. Returns JSON with `session`, `verification_uri`,
/// `user_code` (and `message`) or `{ok:false,...}`.
pub fn device_start_json() -> String {
    let auth = AuthConfig::default();
    let device_url = format!(
        "https://login.microsoftonline.com/{}/oauth2/v2.0/devicecode",
        auth.tenant
    );
    let token_url = format!(
        "https://login.microsoftonline.com/{}/oauth2/v2.0/token",
        auth.tenant
    );

    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let http = reqwest::Client::new();
            let resp = http
                .post(&device_url)
                .form(&[("client_id", auth.client_id), ("scope", auth.scope)])
                .send()
                .await
                .map_err(|e| format!("devicecode request: {}", e))?;
            let status = resp.status();
            let body: serde_json::Value = resp
                .json()
                .await
                .map_err(|e| format!("devicecode parse: {}", e))?;
            if !status.is_success() {
                return Err(format!("devicecode http {}: {}", status, body));
            }
            let get = |k: &str| {
                body.get(k)
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
                    .ok_or_else(|| format!("devicecode missing {}", k))
            };
            let device_code = get("device_code")?;
            let user_code = get("user_code")?;
            let verification_uri = get("verification_uri")?;
            let message = body
                .get("message")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let expires_in = body.get("expires_in").and_then(|v| v.as_u64()).unwrap_or(900);
            let interval = body.get("interval").and_then(|v| v.as_u64()).unwrap_or(5);

            let id = new_session_id();
            lock_sessions().insert(
                id.clone(),
                PendingSession {
                    device_code,
                    token_url,
                    client_id: auth.client_id.to_string(),
                    created_at: now_secs(),
                    expires_in,
                    interval,
                },
            );
            Ok(json!({
                "ok": true,
                "session": id,
                "verification_uri": verification_uri,
                "user_code": user_code,
                "message": message,
                "expires_in": expires_in,
                "interval": interval,
            })
            .to_string())
        })
    };

    match run() {
        Ok(s) => s,
        Err(e) => err_json("device_start", e),
    }
}

/// Single poll attempt for `session`. Returns:
/// - `{ok:true, status:"pending"}` — keep polling after `interval` secs
/// - `{ok:true, status:"complete", tokens:{...}}` — tokens saved
/// - `{ok:false, ...}` — fatal (session dropped)
pub fn device_poll_json(session: &str) -> String {
    let (device_code, token_url, client_id, interval) = {
        let map = lock_sessions();
        match map.get(session) {
            Some(s) => {
                if now_secs() > s.created_at + s.expires_in {
                    drop(map);
                    lock_sessions().remove(session);
                    return err_json("device_expired", "device code expired; start again");
                }
                (
                    s.device_code.clone(),
                    s.token_url.clone(),
                    s.client_id.clone(),
                    s.interval,
                )
            }
            None => return err_json("no_session", "unknown or finished session"),
        }
    };

    let run = || -> Result<serde_json::Value, (bool, String)> {
        // Ok(value) = complete; Err((retryable, detail))
        let rt = rt().map_err(|e| (false, e))?;
        rt.block_on(async {
            let http = reqwest::Client::new();
            let resp = http
                .post(&token_url)
                .form(&[
                    ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                    ("device_code", &device_code),
                    ("client_id", &client_id),
                ])
                .send()
                .await
                .map_err(|e| (true, format!("token request: {}", e)))?;
            let body: serde_json::Value = resp
                .json()
                .await
                .map_err(|e| (true, format!("token parse: {}", e)))?;
            if let Some(tok) = body.get("access_token").and_then(|v| v.as_str()) {
                let refresh = body
                    .get("refresh_token")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let expires_in = body.get("expires_in").and_then(|v| v.as_u64());
                return Ok(json!({
                    "access_token": tok.to_string(),
                    "refresh_token": refresh,
                    "expires_in": expires_in,
                }));
            }
            let code = body
                .get("error")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown");
            match code {
                "authorization_pending" | "slow_down" => {
                    Err((true, "pending".to_string()))
                }
                _ => Err((false, format!("{}: {}", code, body))),
            }
        })
    };

    match run() {
        Ok(t) => {
            // Save AAD tokens, then derive Skype/Graph/IC3/Recorder via refresh.
            let save = (|| -> Result<(), String> {
                let rt = rt()?;
                rt.block_on(async {
                    let mut cfg = Config::load().map_err(|e| e.to_string())?;
                    cfg.set_access_token(
                        t["access_token"].as_str().unwrap_or("").to_string(),
                        t["expires_in"].as_u64(),
                    );
                    let rt_tok = t["refresh_token"].as_str().unwrap_or("");
                    if !rt_tok.is_empty() {
                        cfg.set_refresh_token(rt_tok.to_string());
                    }
                    cfg.save().map_err(|e| e.to_string())?;
                    // Best-effort derived tokens (each warns, never fails login).
                    let _ = ost::auth::oauth::refresh().await;
                    Ok(())
                })
            })();
            if let Err(e) = save {
                return err_json("token_save", e);
            }
            lock_sessions().remove(session);
            let tokens = Config::load()
                .map(|c| token_summary(&c))
                .unwrap_or(json!({}));
            json!({"ok": true, "status": "complete", "tokens": tokens}).to_string()
        }
        Err((true, _)) => json!({"ok": true, "status": "pending", "interval": interval}).to_string(),
        Err((false, detail)) => {
            lock_sessions().remove(session);
            err_json("device_poll", detail)
        }
    }
}

// ---------------------------------------------------------------------------
// Chats
// ---------------------------------------------------------------------------

fn chat_to_json(c: &ost::api::ChatInfo) -> serde_json::Value {
    json!({
        "id": c.id,
        "name": c.name,
        "is_group": c.is_group,
        "last_message_time": c.last_message_time,
        "last_message_sender": c.last_message_sender,
        "last_message_preview": c.last_message_preview,
    })
}

/// Structured chat list as JSON. Requires sign-in; unsigned yields `{ok:false}`.
pub fn chats_json(limit: usize) -> String {
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let chats = ost::api::list_chats_data(&client, limit)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = chats.iter().map(chat_to_json).collect();
            Ok(json!({"ok": true, "chats": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("chats", e),
    }
}

// ---------------------------------------------------------------------------
// Messages (one chat: history + send)
// ---------------------------------------------------------------------------

fn message_to_json(m: &ost::api::MessageInfo) -> serde_json::Value {
    json!({
        "id": m.id,
        "sender": m.sender,
        "timestamp": m.timestamp,
        "content": m.content,
    })
}

/// Full message history for one chat as JSON. Requires sign-in; unsigned
/// yields `{ok:false}`. Empty `chat_id` is rejected before any network.
pub fn messages_json(chat_id: &str, limit: usize) -> String {
    if chat_id.trim().is_empty() {
        return err_json("arg", "empty chat_id");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let msgs = ost::api::read_messages_data(&client, chat_id, limit)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = msgs.iter().map(message_to_json).collect();
            Ok(json!({"ok": true, "chat_id": chat_id, "messages": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("messages", e),
    }
}

/// Post one message to a chat. Returns `{ok:true, chat_id}` or `{ok:false}`.
/// Empty `chat_id`/`text` are rejected before any network.
pub fn send_json(chat_id: &str, text: &str) -> String {
    if chat_id.trim().is_empty() {
        return err_json("arg", "empty chat_id");
    }
    if text.trim().is_empty() {
        return err_json("arg", "empty text");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            ost::api::send_message_with_client(&client, chat_id, text)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "chat_id": chat_id}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("send", e),
    }
}

// ---------------------------------------------------------------------------
// Trouter event channel
// ---------------------------------------------------------------------------

struct TrouterState {
    rt: Arc<tokio::runtime::Runtime>,
    shutdown: Option<tokio::sync::oneshot::Sender<()>>,
    task: tokio::task::JoinHandle<()>,
    driver: Option<std::thread::JoinHandle<()>>,
}

fn trouter_state() -> &'static Mutex<Option<TrouterState>> {
    static T: OnceLock<Mutex<Option<TrouterState>>> = OnceLock::new();
    T.get_or_init(|| Mutex::new(None))
}

/// 0 started, -1 already running, -2 no usable auth, -3 runtime failure.
pub fn trouter_start() -> c_int {
    let mut guard = trouter_state().lock().unwrap_or_else(|e| e.into_inner());
    if guard.is_some() {
        return -1;
    }
    // Fail fast without usable tokens (else the loop retries forever).
    match Config::load() {
        Ok(cfg) => match cfg.get_skype_token() {
            Some(t) if !t.is_expired() => {}
            _ => return -2,
        },
        Err(_) => return -2,
    }
    let rt = match rt().map(Arc::new) {
        Ok(r) => r,
        Err(_) => return -3,
    };
    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();
    let task = rt.spawn(async move {
        let _ = ost::trouter::connect_and_run().await;
    });
    let rt2 = Arc::clone(&rt);
    let driver = std::thread::Builder::new()
        .name("ostmac-trouter".to_string())
        .spawn(move || {
            let _ = rt2.block_on(async move {
                let _ = shutdown_rx.await;
            });
        })
        .ok();
    // Drop stale queued events from any previous run.
    let _ = ost::event_hub::drain(1024);
    *guard = Some(TrouterState {
        rt,
        shutdown: Some(shutdown_tx),
        task,
        driver,
    });
    0
}

/// Drain queued Trouter events as `{ok:true, events:[...]}` (raw JSON strings).
pub fn trouter_poll_json() -> String {
    let events = ost::event_hub::drain(64);
    let parsed: Vec<serde_json::Value> = events
        .iter()
        .map(|e| serde_json::from_str(e).unwrap_or(json!({"raw": e})))
        .collect();
    json!({"ok": true, "events": parsed}).to_string()
}

/// 0 stopped, -1 was not running.
pub fn trouter_stop() -> c_int {
    let mut guard = trouter_state().lock().unwrap_or_else(|e| e.into_inner());
    match guard.take() {
        Some(mut st) => {
            st.task.abort();
            if let Some(tx) = st.shutdown.take() {
                let _ = tx.send(());
            }
            if let Some(h) = st.driver.take() {
                let _ = h.join();
            }
            0
        }
        None => -1,
    }
}

// ---------------------------------------------------------------------------
// C ABI (Swift calls these; JSON over the boundary)
// ---------------------------------------------------------------------------

static VERSION_C: &[u8] = b"0.1.0\0";

/// Static version string. Never freed.
#[no_mangle]
pub extern "C" fn ostmac_version() -> *const c_char {
    VERSION_C.as_ptr() as *const c_char
}

/// 0 = core usable (runtime builds). No network.
#[no_mangle]
pub extern "C" fn ostmac_init() -> c_int {
    match rt() {
        Ok(_) => 0,
        Err(_) => -1,
    }
}

/// Auth status JSON. Caller frees with [`ostmac_free`].
#[no_mangle]
pub extern "C" fn ostmac_status() -> *mut c_char {
    string_to_c(status_json())
}

/// Device-code start JSON (`session`, `verification_uri`, `user_code`).
#[no_mangle]
pub extern "C" fn ostmac_device_start() -> *mut c_char {
    string_to_c(device_start_json())
}

/// Single poll for `session` (NUL-terminated). See [`device_poll_json`].
#[no_mangle]
pub extern "C" fn ostmac_device_poll(session: *const c_char) -> *mut c_char {
    match cstr_to_string(session) {
        Ok(s) => string_to_c(device_poll_json(&s)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Chat list JSON. See [`chats_json`].
#[no_mangle]
pub extern "C" fn ostmac_chats(limit: c_int) -> *mut c_char {
    let lim = if limit <= 0 { 20 } else { limit as usize };
    string_to_c(chats_json(lim))
}

/// Message history JSON for one chat. See [`messages_json`].
#[no_mangle]
pub extern "C" fn ostmac_messages(chat_id: *const c_char, limit: c_int) -> *mut c_char {
    let lim = if limit <= 0 { 50 } else { limit as usize };
    match cstr_to_string(chat_id) {
        Ok(id) => string_to_c(messages_json(&id, lim)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Post one message to a chat. See [`send_json`].
#[no_mangle]
pub extern "C" fn ostmac_send(chat_id: *const c_char, text: *const c_char) -> *mut c_char {
    let id = match cstr_to_string(chat_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(text) {
        Ok(t) => string_to_c(send_json(&id, &t)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Start background Trouter push. See [`trouter_start`].
#[no_mangle]
pub extern "C" fn ostmac_trouter_start() -> c_int {
    trouter_start()
}

/// Drain queued Trouter events as JSON.
#[no_mangle]
pub extern "C" fn ostmac_trouter_poll() -> *mut c_char {
    string_to_c(trouter_poll_json())
}

/// Stop background Trouter. See [`trouter_stop`].
#[no_mangle]
pub extern "C" fn ostmac_trouter_stop() -> c_int {
    trouter_stop()
}

/// Free a string returned by any `ostmac_*` call. Null-safe.
#[no_mangle]
pub extern "C" fn ostmac_free(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(s);
    }
}

// ---------------------------------------------------------------------------
// Tests (deterministic: no network, no sign-in dependency)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_envelope_has_expected_keys() {
        let v: serde_json::Value = serde_json::from_str(&status_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert!(v["signed_in"].is_boolean());
        for k in ["aad", "graph", "ic3", "recorder", "skype"] {
            assert!(v["tokens"][k]["present"].is_boolean(), "missing {}", k);
        }
        assert!(v["tokens"]["refresh_present"].is_boolean());
    }

    #[test]
    fn chat_json_shape() {
        let c = ost::api::ChatInfo {
            id: "19:abc@thread".to_string(),
            name: "Grp".to_string(),
            is_group: true,
            last_message_time: Some("t".to_string()),
            last_message_sender: Some("s".to_string()),
            last_message_preview: Some("p".to_string()),
        };
        let v = chat_to_json(&c);
        assert_eq!(v["id"], "19:abc@thread");
        assert_eq!(v["is_group"], true);
        assert_eq!(v["last_message_preview"], "p");
    }

    #[test]
    fn message_json_shape() {
        let m = ost::api::MessageInfo {
            id: "m1".to_string(),
            sender: "A Sender".to_string(),
            timestamp: "2026-09-22T12:00:00Z".to_string(),
            content: "hi".to_string(),
        };
        let v = message_to_json(&m);
        assert_eq!(v["id"], "m1");
        assert_eq!(v["sender"], "A Sender");
        assert_eq!(v["timestamp"], "2026-09-22T12:00:00Z");
        assert_eq!(v["content"], "hi");
    }

    #[test]
    fn messages_empty_chat_id_is_error() {
        for bad in ["", "   "] {
            let v: serde_json::Value =
                serde_json::from_str(&messages_json(bad, 10)).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn send_empty_args_is_error() {
        for (id, text) in [("", "hi"), ("19:x", ""), ("19:x", "  ")] {
            let v: serde_json::Value =
                serde_json::from_str(&send_json(id, text)).unwrap();
            assert_eq!(v["ok"], false, "id={:?} text={:?}", id, text);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_messages_null_is_arg_error() {
        unsafe {
            let p = ostmac_messages(std::ptr::null(), 10);
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_send_empty_text_roundtrip() {
        let id = CString::new("19:x").unwrap();
        let tx = CString::new("").unwrap();
        unsafe {
            let p = ostmac_send(id.as_ptr(), tx.as_ptr());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn device_poll_unknown_session_is_error() {
        let v: serde_json::Value =
            serde_json::from_str(&device_poll_json("dc-nope")).unwrap();
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"], "no_session");
    }

    #[test]
    fn trouter_poll_empty_envelope() {
        let _ = ost::event_hub::drain(1024); // isolate from other tests
        let v: serde_json::Value = serde_json::from_str(&trouter_poll_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["events"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn trouter_event_roundtrip() {
        let _ = ost::event_hub::drain(1024);
        ost::event_hub::publish(r#"{"kind":"ping","n":1}"#.to_string());
        let v: serde_json::Value = serde_json::from_str(&trouter_poll_json()).unwrap();
        assert_eq!(v["events"][0]["kind"], "ping");
        // Drained: second poll empty.
        let v2: serde_json::Value = serde_json::from_str(&trouter_poll_json()).unwrap();
        assert_eq!(v2["events"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn trouter_stop_when_idle() {
        assert_eq!(trouter_stop(), -1);
    }
}