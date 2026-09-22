//! ostmac-core: minimal embeddable surface over vendored `ost`.
//!
//! Exposes seven capabilities to Swift (via C ABI, JSON over the FFI):
//! - auth: RFC 8628 device-code `start` (get URL+code) and single-shot `poll`
//! - whoami: current user (Graph /me), process-cached until sign-out
//! - chats: structured chat list (requires sign-in)
//! - teams: joined teams with channels (requires sign-in)
//! - messages: full history for one chat (requires sign-in)
//! - send: post one message to a chat (requires sign-in)
//! - presence: own get/set + per-user get (Graph presence, requires sign-in)
//! - trouter: background push connection with a polled event channel
//! - calls: signaling-only place/accept/end + echo-bot + recorder inject
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

pub mod av;
pub mod calls;
pub mod realtime;

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

pub(crate) fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub(crate) fn err_json(code: &str, detail: impl std::fmt::Display) -> String {
    json!({"ok": false, "error": code, "detail": detail.to_string()}).to_string()
}

pub(crate) fn cstr_to_string(p: *const c_char) -> Result<String, String> {
    if p.is_null() {
        return Err("null pointer".to_string());
    }
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .map(|s| s.to_string())
        .map_err(|e| format!("invalid utf-8: {}", e))
}

pub(crate) fn string_to_c(s: String) -> *mut c_char {
    CString::new(s).map(|c| c.into_raw()).unwrap_or(std::ptr::null_mut())
}

pub(crate) fn rt() -> Result<tokio::runtime::Runtime, String> {
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
            whoami_cache_clear(); // new sign-in may be a different user
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
// Refresh + sign-out (om-authux lane)
// ---------------------------------------------------------------------------

/// Refresh AAD + derived tokens via the stored refresh token. Returns:
/// - `{ok:true, refreshed:true, tokens:{...}}` — refresh succeeded
/// - `{ok:true, refreshed:false}` — no refresh token stored (run device flow)
/// - `{ok:false, ...}` — refresh attempted and failed (retryable)
pub fn refresh_json() -> String {
    let run = || -> Result<bool, String> {
        let rt = rt()?;
        rt.block_on(async {
            ost::auth::oauth::refresh()
                .await
                .map_err(|e| format!("{:#}", e))
        })
    };
    match run() {
        Ok(true) => {
            let tokens = Config::load()
                .map(|c| token_summary(&c))
                .unwrap_or(json!({}));
            json!({"ok": true, "refreshed": true, "tokens": tokens}).to_string()
        }
        Ok(false) => json!({"ok": true, "refreshed": false}).to_string(),
        Err(e) => err_json("refresh", e),
    }
}

/// Clear all stored tokens (sign out). Drops pending device-code sessions
/// too. Returns `{ok:true}` or `{ok:false}` when the config can't load/save.
pub fn sign_out_json() -> String {
    lock_sessions().clear();
    whoami_cache_clear();
    let run = || -> Result<(), String> {
        let mut cfg = Config::load().map_err(|e| e.to_string())?;
        cfg.clear_tokens();
        cfg.save().map_err(|e| e.to_string())
    };
    match run() {
        Ok(()) => json!({"ok": true}).to_string(),
        Err(e) => err_json("sign_out", e),
    }
}

// ---------------------------------------------------------------------------
// Whoami (om-identity-own lane)
// ---------------------------------------------------------------------------

/// Process-lifetime cache of the last successful whoami envelope.
/// Who Am I can't change without a sign-out/sign-in cycle, and both
/// [`sign_out_json`] and [`device_poll_json`] (on complete) clear it.
fn whoami_cache() -> &'static Mutex<Option<String>> {
    static W: OnceLock<Mutex<Option<String>>> = OnceLock::new();
    W.get_or_init(|| Mutex::new(None))
}

fn whoami_cache_clear() {
    *whoami_cache().lock().unwrap_or_else(|e| e.into_inner()) = None;
}

#[cfg(test)]
fn whoami_cache_store(s: String) {
    *whoami_cache().lock().unwrap_or_else(|e| e.into_inner()) = Some(s);
}

fn whoami_envelope(id: &str, display_name: &str, mail: Option<&str>) -> String {
    json!({
        "ok": true,
        "id": id,
        "display_name": display_name,
        "mail": mail,
    })
    .to_string()
}

/// Current user via Graph /me. Requires sign-in; unsigned yields
/// `{ok:false}`. First call hits network, later calls serve the cache.
pub fn whoami_json() -> String {
    if let Some(hit) = whoami_cache()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
    {
        return hit;
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let info = ost::api::whoami_data(&client)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(whoami_envelope(&info.id, &info.display_name, info.mail.as_deref()))
        })
    };
    match run() {
        Ok(s) => {
            *whoami_cache().lock().unwrap_or_else(|e| e.into_inner()) = Some(s.clone());
            s
        }
        Err(e) => err_json("whoami", e),
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
// Teams (joined teams + channels; channel ids open via messages/send)
// ---------------------------------------------------------------------------

fn channel_to_json(c: &ost::api::ChannelInfo) -> serde_json::Value {
    json!({
        "id": c.id,
        "name": c.name,
    })
}

fn team_to_json(t: &ost::api::TeamInfo) -> serde_json::Value {
    let channels: Vec<_> = t.channels.iter().map(channel_to_json).collect();
    json!({
        "id": t.id,
        "name": t.name,
        "channels": channels,
    })
}

/// Joined teams with their channels as JSON. Requires sign-in; unsigned
/// yields `{ok:false}`. Channel ids open as conversations through the
/// same `messages`/`send` path as chat ids (ost TUI parity).
pub fn teams_json() -> String {
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let teams = ost::api::list_teams_data(&client)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = teams.iter().map(team_to_json).collect();
            Ok(json!({"ok": true, "teams": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("teams", e),
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
        "raw": m.raw,
    })
}

fn page_to_json(chat_id: &str, page: &ost::api::MessagesPage) -> String {
    let items: Vec<_> = page.messages.iter().map(message_to_json).collect();
    json!({
        "ok": true,
        "chat_id": chat_id,
        "messages": items,
        "page_token": page.backward_link,
    })
    .to_string()
}

/// Full message history for one chat as JSON. Requires sign-in; unsigned
/// yields `{ok:false}`. Empty `chat_id` is rejected before any network.
/// `page_token` (opaque server cursor, null when exhausted) feeds
/// [`messages_page_json`] for older history.
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
            let page = ost::api::read_messages_page(&client, chat_id, limit, None)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(page_to_json(chat_id, &page))
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("messages", e),
    }
}

/// One older page of history. `page_token` is the previous response's
/// opaque cursor; only `https://…/conversations/…` tokens are followed.
/// Empty args are rejected before any network.
pub fn messages_page_json(chat_id: &str, page_token: &str, limit: usize) -> String {
    if chat_id.trim().is_empty() {
        return err_json("arg", "empty chat_id");
    }
    if page_token.trim().is_empty() {
        return err_json("arg", "empty page_token");
    }
    if !page_token.starts_with("https://") || !page_token.contains("/conversations/") {
        return err_json("arg", "page_token not a conversations URL");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let page = ost::api::read_messages_page(&client, chat_id, limit, Some(page_token))
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(page_to_json(chat_id, &page))
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("messages_page", e),
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
// Media (om-richmedia lane: auth'd inline-image fetch for `<img>` mining)
// ---------------------------------------------------------------------------

fn media_envelope(data: &[u8], content_type: &Option<String>) -> String {
    use base64::Engine;
    json!({
        "ok": true,
        "data_base64": base64::engine::general_purpose::STANDARD.encode(data),
        "content_type": content_type,
    })
    .to_string()
}

/// Fetch one inline-image URL as `{ok:true, data_base64, content_type?}`.
/// Microsoft media hosts attach the Skype token; public hosts fetch without
/// auth (see `ost::api::media`). Empty/non-https URLs are rejected before
/// any network. Requires sign-in for auth'd hosts; unsigned yields
/// `{ok:false}`. Caller frees.
pub fn media_fetch_json(url: &str) -> String {
    let u = url.trim();
    if u.is_empty() {
        return err_json("arg", "empty url");
    }
    if !u.starts_with("https://") {
        return err_json("arg", "media URL must be https");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let mb = ost::api::fetch_media_data(&client, u)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(media_envelope(&mb.data, &mb.content_type))
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("media", e),
    }
}

// ---------------------------------------------------------------------------
// Presence (om-presence lane: ost CLI get/set + TUI LoadPresence parity)
// ---------------------------------------------------------------------------

fn presence_envelope(availability: &str, activity: &str) -> String {
    json!({
        "ok": true,
        "availability": availability,
        "activity": activity,
    })
    .to_string()
}

/// ost `set_presence` status table, verbatim (lowercased input):
/// available, busy, dnd|donotdisturb, away, offline.
fn presence_status_pair(status: &str) -> Option<(&'static str, &'static str)> {
    match status.to_lowercase().as_str() {
        "available" => Some(("Available", "Available")),
        "busy" => Some(("Busy", "InACall")),
        "dnd" | "donotdisturb" => Some(("DoNotDisturb", "Presenting")),
        "away" => Some(("Away", "Away")),
        "offline" => Some(("Offline", "OffWork")),
        _ => None,
    }
}

/// Own presence via Graph /me/presence (ost `get_presence_data`).
/// `{ok:true, availability, activity}` or `{ok:false}`.
pub fn presence_json() -> String {
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let info = ost::api::get_presence_data(&client)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(presence_envelope(&info.availability, &info.activity))
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("presence", e),
    }
}

/// Set own preferred presence (ost `set_presence` table + body, minus the
/// CLI print). Unknown/empty `status` is rejected before any network.
/// Returns the applied `{ok:true, availability, activity}`.
pub fn set_presence_json(status: &str) -> String {
    let want = status.trim();
    if want.is_empty() {
        return err_json("arg", "empty status");
    }
    let (availability, activity) = match presence_status_pair(want) {
        Some(p) => p,
        None => {
            return err_json(
                "arg",
                format!(
                    "Unknown status: {}. Use: available, busy, dnd, away, offline",
                    want
                ),
            )
        }
    };
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let body = serde_json::json!({
                "sessionId": "teams-cli",
                "availability": availability,
                "activity": activity,
                "expirationDuration": "PT1H"
            });
            client
                .graph_post("/me/presence/setUserPreferredPresence", &body)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(presence_envelope(availability, activity))
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("presence_set", e),
    }
}

/// One other user's presence via Graph /users/{id}/presence (same wire
/// shape as /me/presence). `user_id` is an Entra ID or UPN; empty or
/// path-breaking ids are rejected before any network.
/// `{ok:true, id, availability, activity}` or `{ok:false}`.
pub fn user_presence_json(user_id: &str) -> String {
    let id = user_id.trim();
    if id.is_empty() {
        return err_json("arg", "empty user_id");
    }
    if id.contains('/') || id.chars().any(|c| c.is_whitespace()) {
        return err_json("arg", "user_id must not contain '/' or whitespace");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let resp = client
                .graph_get(&format!("/users/{}/presence", id))
                .await
                .map_err(|e| format!("{:#}", e))?;
            #[derive(serde::Deserialize)]
            struct P {
                availability: String,
                activity: String,
            }
            let p: P = resp
                .json()
                .await
                .map_err(|e| format!("Failed to parse presence response: {}", e))?;
            Ok(json!({
                "ok": true,
                "id": id,
                "availability": p.availability,
                "activity": p.activity,
            })
            .to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("presence_user", e),
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
    // UI-driven signaling: the bg loop must not auto-answer incoming
    // calls (ost honors this; invitations still reach event_hub).
    std::env::set_var("TEAMS_MANUAL_CALLS", "1");
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

/// Drain queued Trouter events as typed realtime messages.
///
/// `{ok:true, messages:[{chat_id,id,sender,text,time,is_edit,edited_id?}],
/// resync:bool, skipped:n, calls:[{kind,call_id,peer,peer_name,detail?}]}`.
/// `resync` is true when a `trouter.message_loss` frame was seen: the UI
/// must re-fetch visible conversations (push had a gap). `skipped` counts
/// non-message frames (handshake, presence…). `calls` carries incoming
/// invitations / remote ends (also recorded in the call slot).
/// NOTE: drains the same queue as [`trouter_poll_json`] — use one consumer.
pub fn trouter_poll_typed_json() -> String {
    let events = ost::event_hub::drain(64);
    let mut values = Vec::with_capacity(events.len());
    let mut unparseable = 0usize;
    for e in &events {
        match serde_json::from_str(e) {
            Ok(v) => values.push(v),
            Err(_) => unparseable += 1,
        }
    }
    let mut batch = realtime::parse_batch(&values);
    batch.skipped += unparseable;
    let call_events = calls::scan_events(&events);
    json!({
        "ok": true,
        "messages": batch.messages,
        "resync": batch.resync,
        "skipped": batch.skipped,
        "calls": call_events,
    })
    .to_string()
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

static VERSION_C: &[u8] = b"1.0.0\0";

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

/// Current-user JSON (Graph /me, cached). See [`whoami_json`].
/// Caller frees with [`ostmac_free`].
#[no_mangle]
pub extern "C" fn ostmac_whoami() -> *mut c_char {
    string_to_c(whoami_json())
}

/// Chat list JSON. See [`chats_json`].
#[no_mangle]
pub extern "C" fn ostmac_chats(limit: c_int) -> *mut c_char {
    let lim = if limit <= 0 { 20 } else { limit as usize };
    string_to_c(chats_json(lim))
}

/// Joined-teams JSON (requires sign-in). See [`teams_json`].
#[no_mangle]
pub extern "C" fn ostmac_teams() -> *mut c_char {
    string_to_c(teams_json())
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

/// Older history page for one chat. See [`messages_page_json`].
#[no_mangle]
pub extern "C" fn ostmac_messages_page(
    chat_id: *const c_char,
    page_token: *const c_char,
    limit: c_int,
) -> *mut c_char {
    let lim = if limit <= 0 { 50 } else { limit as usize };
    let id = match cstr_to_string(chat_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(page_token) {
        Ok(t) => string_to_c(messages_page_json(&id, &t, lim)),
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

/// Fetch one inline-image URL. See [`media_fetch_json`]. Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_media_fetch(url: *const c_char) -> *mut c_char {
    match cstr_to_string(url) {
        Ok(u) => string_to_c(media_fetch_json(&u)),
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

/// Drain queued Trouter events as typed realtime messages.
/// See [`trouter_poll_typed_json`]. Caller frees with [`ostmac_free`].
#[no_mangle]
pub extern "C" fn ostmac_trouter_poll_typed() -> *mut c_char {
    string_to_c(trouter_poll_typed_json())
}

/// Stop background Trouter. See [`trouter_stop`].
#[no_mangle]
pub extern "C" fn ostmac_trouter_stop() -> c_int {
    trouter_stop()
}

/// Refresh tokens via the stored refresh token. See [`refresh_json`].
#[no_mangle]
pub extern "C" fn ostmac_refresh() -> *mut c_char {
    string_to_c(refresh_json())
}

/// Clear all stored tokens (sign out). See [`sign_out_json`].
#[no_mangle]
pub extern "C" fn ostmac_sign_out() -> *mut c_char {
    string_to_c(sign_out_json())
}

/// Own presence JSON (Graph /me/presence). See [`presence_json`].
/// Caller frees with [`ostmac_free`].
#[no_mangle]
pub extern "C" fn ostmac_presence() -> *mut c_char {
    string_to_c(presence_json())
}

/// Set own preferred presence. `status` is one of: available, busy,
/// dnd (donotdisturb), away, offline (case-insensitive). See
/// [`set_presence_json`]. Caller frees with [`ostmac_free`].
#[no_mangle]
pub extern "C" fn ostmac_presence_set(status: *const c_char) -> *mut c_char {
    match cstr_to_string(status) {
        Ok(s) => string_to_c(set_presence_json(&s)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Current call slot JSON. See [`calls::call_status_json`].
#[no_mangle]
pub extern "C" fn ostmac_call_status() -> *mut c_char {
    string_to_c(calls::call_status_json())
}

/// Place an outgoing call to a thread id (1:1 or channel), signaling
/// only. Blocks up to `timeout_secs` (clamped 5..120) waiting for the
/// answer. See [`calls::call_place_json`].
#[no_mangle]
pub extern "C" fn ostmac_call_place(
    thread_id: *const c_char,
    timeout_secs: c_int,
) -> *mut c_char {
    match cstr_to_string(thread_id) {
        Ok(t) => string_to_c(calls::call_place_json(&t, timeout_secs as i32)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// One other user's presence JSON (`user_id` = Entra ID or UPN).
/// See [`user_presence_json`]. Caller frees with [`ostmac_free`].
#[no_mangle]
pub extern "C" fn ostmac_presence_user(user_id: *const c_char) -> *mut c_char {
    match cstr_to_string(user_id) {
        Ok(id) => string_to_c(user_presence_json(&id)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Place the echo-bot test call, signaling only. See [`calls::call_echo_json`].
#[no_mangle]
pub extern "C" fn ostmac_call_echo(timeout_secs: c_int) -> *mut c_char {
    string_to_c(calls::call_echo_json(timeout_secs as i32))
}

/// Accept the ringing incoming call. See [`calls::call_accept_json`].
#[no_mangle]
pub extern "C" fn ostmac_call_accept() -> *mut c_char {
    string_to_c(calls::call_accept_json())
}

/// End/decline the active call. See [`calls::call_end_json`].
#[no_mangle]
pub extern "C" fn ostmac_call_end() -> *mut c_char {
    string_to_c(calls::call_end_json())
}

/// Inject the recorder bot into the connected outgoing call.
/// See [`calls::call_record_inject_json`].
#[no_mangle]
pub extern "C" fn ostmac_call_record_inject() -> *mut c_char {
    string_to_c(calls::call_record_inject_json())
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
    fn team_json_shape() {
        let t = ost::api::TeamInfo {
            id: "team-1".to_string(),
            name: "Engineering".to_string(),
            channels: vec![
                ost::api::ChannelInfo {
                    id: "19:general@thread.tacv2".to_string(),
                    name: "General".to_string(),
                },
                ost::api::ChannelInfo {
                    id: "19:random@thread.tacv2".to_string(),
                    name: "Random".to_string(),
                },
            ],
        };
        let v = team_to_json(&t);
        assert_eq!(v["id"], "team-1");
        assert_eq!(v["name"], "Engineering");
        assert_eq!(v["channels"].as_array().unwrap().len(), 2);
        assert_eq!(v["channels"][0]["id"], "19:general@thread.tacv2");
        assert_eq!(v["channels"][0]["name"], "General");
        assert_eq!(v["channels"][1]["name"], "Random");
    }

    #[test]
    fn team_json_empty_channels() {
        let t = ost::api::TeamInfo {
            id: "team-2".to_string(),
            name: "Lonely".to_string(),
            channels: vec![],
        };
        let v = team_to_json(&t);
        assert_eq!(v["name"], "Lonely");
        assert_eq!(v["channels"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn message_json_shape() {
        let m = ost::api::MessageInfo {
            id: "m1".to_string(),
            sender: "A Sender".to_string(),
            timestamp: "2026-09-22T12:00:00Z".to_string(),
            content: "hi".to_string(),
            raw: "<p>hi</p>".to_string(),
        };
        let v = message_to_json(&m);
        assert_eq!(v["id"], "m1");
        assert_eq!(v["sender"], "A Sender");
        assert_eq!(v["timestamp"], "2026-09-22T12:00:00Z");
        assert_eq!(v["content"], "hi");
        assert_eq!(v["raw"], "<p>hi</p>");
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
    fn media_fetch_rejects_bad_args_without_network() {
        for bad in ["", "   ", "http://h/x.png", "ftp://h/x", "demo://x"] {
            let v: serde_json::Value =
                serde_json::from_str(&media_fetch_json(bad)).unwrap();
            assert_eq!(v["ok"], false, "url={:?}", bad);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn media_envelope_carries_base64_and_type() {
        let v: serde_json::Value =
            serde_json::from_str(&media_envelope(&[0x89, b'P', b'N', b'G'], &Some("image/png".to_string())))
                .unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["content_type"], "image/png");
        let raw = base64::Engine::decode(
            &base64::engine::general_purpose::STANDARD,
            v["data_base64"].as_str().unwrap(),
        )
        .unwrap();
        assert_eq!(raw, vec![0x89, b'P', b'N', b'G']);
        let untyped: serde_json::Value =
            serde_json::from_str(&media_envelope(&[], &None)).unwrap();
        assert!(untyped["content_type"].is_null());
    }

    #[test]
    fn ffi_media_fetch_null_is_arg_error() {
        unsafe {
            let p = ostmac_media_fetch(std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
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
    fn messages_page_rejects_bad_args_without_network() {
        for (id, tok) in [
            ("", "https://h/conversations/x"),
            ("19:x", ""),
            ("19:x", "   "),
            ("19:x", "http://h/conversations/x"), // not https
            ("19:x", "https://evil.example/q"),   // not a conversations URL
        ] {
            let v: serde_json::Value =
                serde_json::from_str(&messages_page_json(id, tok, 10)).unwrap();
            assert_eq!(v["ok"], false, "id={:?} tok={:?}", id, tok);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_messages_page_null_is_arg_error() {
        let id = CString::new("19:x").unwrap();
        unsafe {
            let p = ostmac_messages_page(id.as_ptr(), std::ptr::null(), 10);
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn page_envelope_carries_cursor_and_raw() {
        // om-core-union: convrich success shape (only arg-rejection was pinned).
        let page = ost::api::MessagesPage {
            messages: vec![ost::api::MessageInfo {
                id: "m1".to_string(),
                sender: "A Sender".to_string(),
                timestamp: "2026-09-22T12:00:00Z".to_string(),
                content: "hi Bob".to_string(),
                raw: "<p>hi <at>Bob</at></p>".to_string(),
            }],
            backward_link: Some(
                "https://h/v1/conversations/19:x/messages?page=2".to_string(),
            ),
        };
        let v: serde_json::Value =
            serde_json::from_str(&page_to_json("19:x", &page)).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["chat_id"], "19:x");
        assert_eq!(v["messages"].as_array().unwrap().len(), 1);
        assert_eq!(v["messages"][0]["raw"], "<p>hi <at>Bob</at></p>");
        assert_eq!(
            v["page_token"],
            "https://h/v1/conversations/19:x/messages?page=2"
        );
    }

    #[test]
    fn page_envelope_exhausted_token_is_null() {
        let page = ost::api::MessagesPage {
            messages: vec![],
            backward_link: None,
        };
        let v: serde_json::Value =
            serde_json::from_str(&page_to_json("19:x", &page)).unwrap();
        assert_eq!(v["ok"], true);
        assert!(v["page_token"].is_null());
        assert_eq!(v["messages"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn ffi_messages_page_null_chat_id_is_arg_error() {
        let tok = CString::new("https://h/conversations/19:x").unwrap();
        unsafe {
            let p = ostmac_messages_page(std::ptr::null(), tok.as_ptr(), 10);
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
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
    fn whoami_envelope_shape() {
        let v: serde_json::Value =
            serde_json::from_str(&whoami_envelope("gid-1", "Doe, Jane", Some("j@x.example"))).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["id"], "gid-1");
        assert_eq!(v["display_name"], "Doe, Jane");
        assert_eq!(v["mail"], "j@x.example");
        let v2: serde_json::Value =
            serde_json::from_str(&whoami_envelope("gid-2", "No Mail", None)).unwrap();
        assert!(v2["mail"].is_null());
    }

    #[test]
    fn whoami_cache_hit_serves_without_network() {
        whoami_cache_clear();
        let fake = whoami_envelope("gid-9", "Cached User", None);
        whoami_cache_store(fake.clone());
        // Served from cache: no TeamsClient, no network.
        assert_eq!(whoami_json(), fake);
        unsafe {
            let p = ostmac_whoami();
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            assert_eq!(s, fake);
        }
        whoami_cache_clear();
        assert!(whoami_cache()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .is_none());
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

    #[test]
    fn typed_poll_message_and_loss_and_skip() {
        let _ = ost::event_hub::drain(1024);
        // Captured wire shape: socket.io v1 envelope, name + args.
        ost::event_hub::publish(
            r#"{"name":"trouter.connected","args":[{"ttl":81833,"dur":"1"}]}"#.to_string(),
        );
        ost::event_hub::publish(
            r#"{"name":"trouter.message_loss","args":[{"droppedIndicators":[{"tag":"messaging","etag":"2026-09-22T14:23:45Z"}]}]}"#
                .to_string(),
        );
        // Message resource in native chat-service field style.
        ost::event_hub::publish(
            r#"{"name":"notify","args":[{
                "id":"1758552345000",
                "conversationLink":"https://amer.ng.msg.teams.microsoft.com/v1/users/ME/conversations/19:abc@thread.v2/messages/1758552345000",
                "from":"8:orgid:aaa",
                "imdisplayname":"Doe, Jane",
                "content":"<p>hi <b>there</b> &amp; you</p>",
                "messagetype":"RichText/Html",
                "originalarrivaltime":"2026-09-22T14:25:45.000Z"}]}"#
                .to_string(),
        );
        ost::event_hub::publish(r#"{"kind":"presence","n":1}"#.to_string());
        let v: serde_json::Value =
            serde_json::from_str(&trouter_poll_typed_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["resync"], true);
        assert_eq!(v["messages"].as_array().unwrap().len(), 1);
        let m = &v["messages"][0];
        assert_eq!(m["chat_id"], "19:abc@thread.v2");
        assert_eq!(m["id"], "1758552345000");
        assert_eq!(m["sender"], "Doe, Jane");
        assert_eq!(m["text"], "hi there & you");
        assert_eq!(m["time"], "2026-09-22T14:25:45.000Z");
        assert_eq!(m["is_edit"], false);
        assert_eq!(v["skipped"], 3); // connected + loss + presence
        // Drained: second poll empty, no resync.
        let v2: serde_json::Value =
            serde_json::from_str(&trouter_poll_typed_json()).unwrap();
        assert_eq!(v2["messages"].as_array().unwrap().len(), 0);
        assert_eq!(v2["resync"], false);
    }

    #[test]
    fn typed_poll_edit_detection() {
        let _ = ost::event_hub::drain(1024);
        ost::event_hub::publish(
            r#"{"content":"fixed","messagetype":"RichText/Edit",
                "from":"8:x","threadId":"19:t@thread.v2",
                "skypeeditedid":"111","id":"222"}"#
                .to_string(),
        );
        ost::event_hub::publish(
            r#"{"resource":{"content":"v2","messagetype":"Text",
                "imdisplayname":"A","conversationLink":"https://h/v1/users/ME/conversations/19:u@thread.v2/messages/1",
                "skypeeditedid":"0"}}"#
                .to_string(),
        );
        let v: serde_json::Value =
            serde_json::from_str(&trouter_poll_typed_json()).unwrap();
        assert_eq!(v["messages"].as_array().unwrap().len(), 2);
        assert_eq!(v["messages"][0]["is_edit"], true);
        assert_eq!(v["messages"][0]["edited_id"], "111");
        assert_eq!(v["messages"][1]["is_edit"], true);
        assert_eq!(v["messages"][1]["chat_id"], "19:u@thread.v2");
    }

    #[test]
    fn presence_status_table_matches_ost() {
        // ost api/presence.rs set_presence mapping, verbatim.
        for (input, avail, act) in [
            ("available", "Available", "Available"),
            ("busy", "Busy", "InACall"),
            ("dnd", "DoNotDisturb", "Presenting"),
            ("donotdisturb", "DoNotDisturb", "Presenting"),
            ("away", "Away", "Away"),
            ("offline", "Offline", "OffWork"),
            ("Available", "Available", "Available"),
            ("DND", "DoNotDisturb", "Presenting"),
            ("  busy  ", "Busy", "InACall"),
        ] {
            assert_eq!(
                presence_status_pair(input.trim()),
                Some((avail, act)),
                "input {:?}",
                input
            );
        }
        for bad in ["", "online", "invisible", "be right back", "avail able"] {
            assert_eq!(presence_status_pair(bad), None, "input {:?}", bad);
        }
    }

    #[test]
    fn ffi_call_place_null_is_arg_error() {
        unsafe {
            let p = ostmac_call_place(std::ptr::null(), 30);
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn presence_envelope_shape() {
        let v: serde_json::Value =
            serde_json::from_str(&presence_envelope("Busy", "InACall")).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["availability"], "Busy");
        assert_eq!(v["activity"], "InACall");
    }

    #[test]
    fn set_presence_rejects_bad_status_without_network() {
        for bad in ["", "   ", "online", "invisible"] {
            let v: serde_json::Value =
                serde_json::from_str(&set_presence_json(bad)).unwrap();
            assert_eq!(v["ok"], false, "status {:?}", bad);
            assert_eq!(v["error"], "arg");
        }
        // Unknown-status detail mirrors the ost CLI message.
        let v: serde_json::Value =
            serde_json::from_str(&set_presence_json("online")).unwrap();
        assert!(v["detail"].as_str().unwrap().contains("Unknown status: online"));
    }

    #[test]
    fn user_presence_rejects_bad_ids_without_network() {
        for bad in ["", "   ", "a/b", "a b", "x\ty", "../me"] {
            let v: serde_json::Value =
                serde_json::from_str(&user_presence_json(bad)).unwrap();
            assert_eq!(v["ok"], false, "id {:?}", bad);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_presence_set_null_is_arg_error() {
        unsafe {
            let p = ostmac_presence_set(std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_presence_user_null_is_arg_error() {
        unsafe {
            let p = ostmac_presence_user(std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_presence_set_empty_roundtrip() {
        let st = CString::new("").unwrap();
        unsafe {
            let p = ostmac_presence_set(st.as_ptr());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_call_status_envelope() {
        let _t = calls::test_lock();
        unsafe {
            let p = ostmac_call_status();
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], true);
            assert!(v.get("call").is_some());
        }
    }

    #[test]
    fn typed_poll_carries_calls() {
        let _t = calls::test_lock();
        let _ = ost::event_hub::drain(1024);
        ost::event_hub::publish(
            r#"{"callInvitation":{"callModalities":["Audio"],
                "links":{"end":"https://c.example/end"}},
                "participants":{"from":{"id":"8:orgid:aaa","displayName":"Doe, Jane"}},
                "debugContent":{"callId":"call-9"}}"#
                .to_string(),
        );
        let v: serde_json::Value =
            serde_json::from_str(&trouter_poll_typed_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["calls"].as_array().unwrap().len(), 1);
        assert_eq!(v["calls"][0]["kind"], "incoming");
        assert_eq!(v["calls"][0]["call_id"], "call-9");
        assert_eq!(v["calls"][0]["peer_name"], "Doe, Jane");
        // Slot recorded: status shows the ringing call.
        let s: serde_json::Value =
            serde_json::from_str(&calls::call_status_json()).unwrap();
        assert_eq!(s["call"]["state"], "ringing");
        // Close it so later tests start clean (each clears anyway).
        let _ = calls::scan_events(&[
            r#"{"callEnd":{"code":200,"subCode":0,"phrase":"OK"}}"#.to_string()
        ]);
    }

    #[test]
    fn typed_poll_id_fallback_is_stable() {
        let _ = ost::event_hub::drain(1024);
        let raw = r#"{"content":"x","messagetype":"Text","from":"8:x","threadId":"19:t@thread.v2"}"#;
        ost::event_hub::publish(raw.to_string());
        ost::event_hub::publish(raw.to_string()); // redelivery
        let v: serde_json::Value =
            serde_json::from_str(&trouter_poll_typed_json()).unwrap();
        let a = v["messages"][0]["id"].as_str().unwrap().to_string();
        let b = v["messages"][1]["id"].as_str().unwrap().to_string();
        assert!(a.starts_with("h:"));
        assert_eq!(a, b); // same content => same id => Swift dedupe drops it
    }
}