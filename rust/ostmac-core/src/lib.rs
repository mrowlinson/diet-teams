//! ostmac-core: minimal embeddable surface over vendored `ost`.
//!
//! Exposes seven capabilities to Swift (via C ABI, JSON over the FFI):
//! - auth: RFC 8628 device-code `start` (get URL+code) and single-shot `poll`
//! - whoami: current user (Graph /me), process-cached until sign-out
//! - chats: structured chat list (requires sign-in)
//! - teams: joined teams with channels (requires sign-in)
//! - messages: full history for one chat (requires sign-in)
//! - send/edit/delete: post, edit, or delete a chat message (requires sign-in)
//! - leave: remove self from a group chat thread (requires sign-in)
//! - presence: own get/set + per-user get (Graph presence, requires sign-in)
//! - resolve_mri: Teams `8:orgid:` MRI to Graph user (requires sign-in)
//! - reminders: Microsoft To Do lists/tasks/add/complete (Graph, sign-in)
//! - notes: OneNote notebooks/sections/pages read + paragraph append
//! - trouter: background push connection with a polled event channel
//! - calls: signaling-only place/accept/end + echo-bot + recorder inject
//! - files: shared files list + upload + download + manage (Graph driveItems)
//!
//! Dropped for now: TUI, audio/video, call media.

use std::collections::{HashMap, VecDeque};
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use ost::auth::{AuthConfig, TokenStore};
use ost::config::Config;
use serde_json::json;

pub mod av;
pub mod browser_auth;
pub mod calls;
pub mod live;
pub mod realtime;
pub mod recordings;

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

/// Optional C string: null decodes to `None` (used for group scopes).
pub(crate) fn opt_cstr_to_string(p: *const c_char) -> Result<Option<String>, String> {
    if p.is_null() {
        return Ok(None);
    }
    cstr_to_string(p).map(Some)
}

pub(crate) fn string_to_c(s: String) -> *mut c_char {
    CString::new(s).map(|c| c.into_raw()).unwrap_or(std::ptr::null_mut())
}

/// Process-wide shared tokio runtime. Callers keep per-call `block_on`;
/// only the `Runtime::new` per-call cost is eliminated.
pub(crate) fn rt() -> Result<&'static tokio::runtime::Runtime, String> {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    if let Some(r) = RT.get() {
        return Ok(r);
    }
    // Rare race: two builders, one `set` wins, loser drops an idle runtime.
    let r = tokio::runtime::Runtime::new().map_err(|e| format!("runtime: {}", e))?;
    let _ = RT.set(r);
    RT.get().ok_or_else(|| "runtime: init lost".to_string())
}

/// Shared HTTP client: one connection pool process-wide (owned by `ost`).
/// `Client::clone` is cheap — clones share the pool.
pub(crate) fn http() -> reqwest::Client {
    ost::api::client::shared_http()
}

pub(crate) fn token_summary(cfg: &Config) -> serde_json::Value {
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

/// JSON auth status. Pure read of the cached config, no network.
pub fn status_json() -> String {
    match Config::load_cached() {
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
            let http = http();
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
            let http = http();
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
                    let mut cfg = Config::load_cached().map_err(|e| e.to_string())?;
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
            let tokens = Config::load_cached()
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
            let tokens = Config::load_cached()
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
    browser_auth::clear_browser_sessions();
    whoami_cache_clear();
    let run = || -> Result<(), String> {
        let mut cfg = Config::load_cached().map_err(|e| e.to_string())?;
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

/// Crate-visible clear for the browser-auth module (same new-user rule).
pub(crate) fn whoami_cache_clear_pub() {
    whoami_cache_clear();
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

/// Create (or re-open) a 1:1 chat with `user` (AAD id or UPN).
/// Requires sign-in; unsigned yields `{ok:false}`. Empty refs are
/// rejected before any network.
/// `{ok:true, chat:{id, name, is_group, ...}}` (name empty: Graph
/// sends no 1:1 topic — callers name the thread after the peer).
pub fn chat_create_one_to_one_json(user: &str) -> String {
    if user.trim().is_empty() {
        return err_json("arg", "empty user");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let chat = ost::api::create_one_to_one_chat_data(&client, user)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "chat": chat_to_json(&chat)}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("chat_create", e),
    }
}

// ---------------------------------------------------------------------------
// Teams (joined teams + channels; channel ids open via messages/send)
// ---------------------------------------------------------------------------

fn channel_to_json(c: &ost::api::ChannelInfo) -> serde_json::Value {
    json!({
        "id": c.id,
        "name": c.name,
        "description": c.description,
        "membership_type": c.membership_type,
        "web_url": c.web_url,
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

/// Create one standard channel in a team. Returns
/// `{ok:true, channel:{id,name}}` or `{ok:false}`. Bad `team_id` and
/// blank `name` are rejected before any network; a blank description
/// is dropped (never sent).
pub fn channel_create_json(team_id: &str, name: &str, description: Option<&str>) -> String {
    if let Err(e) = todo_id_ok("team_id", team_id) {
        return e;
    }
    if name.trim().is_empty() {
        return err_json("arg", "empty name");
    }
    let desc = description.filter(|d| !d.trim().is_empty());
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let channel =
                ost::api::create_channel_data(&client, team_id, name, desc)
                    .await
                    .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "channel": channel_to_json(&channel)}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("channel_create", e),
    }
}

/// Join one team by id (self-enroll, `POST /teams/{id}/members`).
/// Returns `{ok:true, team_id}` or `{ok:false}`. Requires sign-in.
/// Empty ids and ids containing path separators are rejected before
/// any network. Join-by-code is out of scope (not a Graph API).
pub fn team_join_json(team_id: &str) -> String {
    let id = team_id.trim();
    if id.is_empty() {
        return err_json("arg", "empty team_id");
    }
    if id.contains(['/', '?', '#']) {
        return err_json("arg", "invalid team_id");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let joined = ost::api::join_team_data(&client, id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "team_id": joined}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("team_join", e),
    }
}

/// Create one standard team and wait for the async operation
/// (`POST /teams` -> 202 + `Content-Location` poll, 3s x 120s cap).
/// Returns `{ok:true, team:{id,name,channels}, polls, elapsed_ms}` or
/// `{ok:false}`. Blank `name` is rejected before any network; a blank
/// description is dropped (never sent).
pub fn team_create_json(name: &str, description: Option<&str>) -> String {
    if name.trim().is_empty() {
        return err_json("arg", "empty name");
    }
    let desc = description.filter(|d| !d.trim().is_empty());
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let created = ost::api::create_team_data(&client, name.trim(), desc)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({
                "ok": true,
                "team": team_to_json(&created.team),
                "polls": created.polls,
                "elapsed_ms": created.elapsed_ms,
            })
            .to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("team_create", e),
    }
}

fn tab_to_json(t: &ost::api::TabInfo) -> serde_json::Value {
    json!({
        "id": t.id,
        "name": t.name,
        "app_id": t.app_id,
        "content_url": t.content_url,
        "website_url": t.website_url,
    })
}

/// One channel's pinned tabs as JSON (read-only). Requires sign-in;
/// unsigned yields `{ok:false}`. Empty `channel_id` is rejected before
/// any network. Swift deep-links Posts/Files/Notes into its own views
/// and opens web-tab URLs in the browser; no content is fetched here.
pub fn tabs_json(channel_id: &str) -> String {
    if channel_id.trim().is_empty() {
        return err_json("arg", "empty channel_id");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let tabs = ost::api::list_tabs_data(&client, channel_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = tabs.iter().map(tab_to_json).collect();
            Ok(json!({"ok": true, "channel_id": channel_id, "tabs": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("tabs", e),
    }
}

// ---------------------------------------------------------------------------
// Team roster (om-h5-members: members + owners)
// ---------------------------------------------------------------------------

fn team_member_to_json(m: &ost::api::TeamMemberInfo) -> serde_json::Value {
    json!({
        "id": m.id,
        "display_name": m.display_name,
        "user_id": m.user_id,
        "email": m.email,
        "roles": m.roles,
        "is_owner": m.is_owner,
    })
}

/// One team's roster as JSON. Requires sign-in; unsigned yields
/// `{ok:false}`. Empty `team_id` is rejected before any network.
/// `{ok:true, team_id, members:[{id, display_name, user_id|null,
/// email|null, roles, is_owner}]}`.
pub fn team_members_json(team_id: &str) -> String {
    if team_id.trim().is_empty() {
        return err_json("arg", "empty team_id");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let members = ost::api::list_team_members_data(&client, team_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = members.iter().map(team_member_to_json).collect();
            Ok(json!({"ok": true, "team_id": team_id.trim(), "members": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("team_members", e),
    }
}

/// Add one user to a team (`owner` grants the owner role).
/// `{ok:true, member}` or `{ok:false}`. Empty args are rejected
/// before any network.
pub fn team_member_add_json(team_id: &str, user: &str, owner: bool) -> String {
    if team_id.trim().is_empty() {
        return err_json("arg", "empty team_id");
    }
    if user.trim().is_empty() {
        return err_json("arg", "empty user");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let m = ost::api::add_team_member_data(&client, team_id, user, owner)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "member": team_member_to_json(&m)}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("team_member_add", e),
    }
}

/// Remove one membership from a team. `member_id` is the roster
/// membership id, not the user id. `{ok:true, team_id, member_id}`
/// or `{ok:false}`. Empty args are rejected before any network.
pub fn team_member_remove_json(team_id: &str, member_id: &str) -> String {
    if team_id.trim().is_empty() {
        return err_json("arg", "empty team_id");
    }
    if member_id.trim().is_empty() {
        return err_json("arg", "empty member_id");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            ost::api::remove_team_member_data(&client, team_id, member_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "team_id": team_id.trim(), "member_id": member_id.trim()})
                .to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("team_member_remove", e),
    }
}

// ---------------------------------------------------------------------------
// Messages (one chat: history + send)
// ---------------------------------------------------------------------------

fn message_to_json(m: &ost::api::MessageInfo) -> serde_json::Value {
    let reactions: Vec<_> = m
        .reactions
        .iter()
        .map(|r| json!({"emoji": r.emoji, "count": r.count}))
        .collect();
    json!({
        "id": m.id,
        "sender": m.sender,
        "timestamp": m.timestamp,
        "content": m.content,
        "raw": m.raw,
        "reactions": reactions,
        "reply_to": m.reply_to,
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

fn search_hit_to_json(h: &ost::api::SearchHitInfo) -> serde_json::Value {
    json!({
        "message_id": h.message_id,
        "chat_id": h.chat_id,
        "team_id": h.team_id,
        "channel_id": h.channel_id,
        "sender": h.sender,
        "timestamp": h.timestamp,
        "preview": h.preview,
        "subject": h.subject,
    })
}

/// Teams message search as JSON (Graph `/search/query`, one `from`/`size`
/// window). Requires sign-in; unsigned yields `{ok:false}`. Empty `query`
/// is rejected before any network; `size` clamps to Graph's `1..=25`.
/// `next_from` (null when exhausted) chains the next window.
pub fn search_json(query: &str, from: usize, size: usize) -> String {
    if query.trim().is_empty() {
        return err_json("arg", "empty query");
    }
    let size = ost::api::clamp_size(size);
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let page = ost::api::search_messages_data(&client, query, from, size)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = page.hits.iter().map(search_hit_to_json).collect();
            Ok(json!({
                "ok": true,
                "query": query,
                "from": from,
                "size": size,
                "total": page.total,
                "more": page.more,
                "next_from": ost::api::next_from(from, &page),
                "hits": items,
            })
            .to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("search", e),
    }
}

/// Post one quote reply to a chat message. Returns `{ok:true, chat_id}`
/// or `{ok:false}`. The parent attribution comes from the caller (no
/// history fetch); ost truncates `parent_text` to the quote snippet.
/// Empty `chat_id`/`parent_id`/`text` are rejected before any network
/// (blank sender/snippet sources fall back to `"?"`/parent id).
pub fn reply_json(
    chat_id: &str,
    parent_id: &str,
    parent_sender: &str,
    parent_text: &str,
    text: &str,
) -> String {
    if chat_id.trim().is_empty() {
        return err_json("arg", "empty chat_id");
    }
    if parent_id.trim().is_empty() {
        return err_json("arg", "empty parent_id");
    }
    if text.trim().is_empty() {
        return err_json("arg", "empty text");
    }
    let sender = if parent_sender.trim().is_empty() {
        "?"
    } else {
        parent_sender
    };
    let snippet_src = if parent_text.trim().is_empty() {
        parent_id
    } else {
        parent_text
    };
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            ost::api::reply_message_with_client(
                &client, chat_id, parent_id, sender, snippet_src, text,
            )
            .await
            .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "chat_id": chat_id}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("reply", e),
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

/// Add one emoji reaction to a message. Returns
/// `{ok:true, chat_id, message_id}` or `{ok:false}`. Empty ids and
/// unsupported emoji are rejected before any network.
pub fn react_json(chat_id: &str, message_id: &str, emoji: &str) -> String {
    if chat_id.trim().is_empty() {
        return err_json("arg", "empty chat_id");
    }
    if message_id.trim().is_empty() {
        return err_json("arg", "empty message_id");
    }
    if ost::api::reaction_type_for_emoji(emoji.trim()).is_none() {
        return err_json("arg", "unsupported reaction emoji");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            ost::api::send_reaction_with_client(&client, chat_id, message_id, emoji.trim())
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "chat_id": chat_id, "message_id": message_id}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("react", e),
    }
}

/// Remove one emoji reaction from a message. Same arg validation and
/// envelope as [`react_json`].
pub fn react_remove_json(chat_id: &str, message_id: &str, emoji: &str) -> String {
    if chat_id.trim().is_empty() {
        return err_json("arg", "empty chat_id");
    }
    if message_id.trim().is_empty() {
        return err_json("arg", "empty message_id");
    }
    if ost::api::reaction_type_for_emoji(emoji.trim()).is_none() {
        return err_json("arg", "unsupported reaction emoji");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            ost::api::remove_reaction_with_client(&client, chat_id, message_id, emoji.trim())
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "chat_id": chat_id, "message_id": message_id}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("react_remove", e),
    }
}

/// Edit one own message. Returns `{ok:true, chat_id, message_id}` or `{ok:false}`.
/// Empty args are rejected before any network.
pub fn edit_json(chat_id: &str, message_id: &str, text: &str) -> String {
    if chat_id.trim().is_empty() {
        return err_json("arg", "empty chat_id");
    }
    if message_id.trim().is_empty() {
        return err_json("arg", "empty message_id");
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
            ost::api::edit_message_with_client(&client, chat_id, message_id, text)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "chat_id": chat_id, "message_id": message_id}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("edit", e),
    }
}

/// Delete one own message. Returns `{ok:true, chat_id, message_id}` or `{ok:false}`.
/// Empty args are rejected before any network.
pub fn delete_json(chat_id: &str, message_id: &str) -> String {

    if chat_id.trim().is_empty() {
        return err_json("arg", "empty chat_id");
    }
    if message_id.trim().is_empty() {
        return err_json("arg", "empty message_id");
    }

    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            ost::api::delete_message_with_client(&client, chat_id, message_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "chat_id": chat_id, "message_id": message_id}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("delete", e),
    }
}

// ---------------------------------------------------------------------------
// Leave chat (om-leave-block lane)
// ---------------------------------------------------------------------------

/// Leave one group chat (remove self from the thread roster). Returns
/// `{ok:true, chat_id}` or `{ok:false}`. Empty ids are rejected before
/// any network.
pub fn leave_json(chat_id: &str) -> String {
    if chat_id.trim().is_empty() {
        return err_json("arg", "empty chat_id");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            ost::api::leave_chat_with_client(&client, chat_id.trim())
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "chat_id": chat_id.trim()}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("leave", e),
    }
}

// ---------------------------------------------------------------------------
// Read receipts (om-receipts lane: consumption horizon send + list)
// ---------------------------------------------------------------------------

fn receipt_to_json(r: &ost::api::ReadReceipt) -> serde_json::Value {
    json!({
        "user": r.user,
        "message_id": r.message_id,
        "horizon": r.horizon,
    })
}

/// Mark one conversation read up to `message_id`. Returns
/// `{ok:true, chat_id, message_id}` or `{ok:false}`. Empty args are
/// rejected before any network.
pub fn mark_read_json(chat_id: &str, message_id: &str) -> String {
    if chat_id.trim().is_empty() {
        return err_json("arg", "empty chat_id");
    }
    if message_id.trim().is_empty() {
        return err_json("arg", "empty message_id");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            ost::api::mark_read_with_client(&client, chat_id.trim(), message_id.trim())
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "chat_id": chat_id.trim(), "message_id": message_id.trim()}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("mark_read", e),
    }
}

/// Peer read positions for one thread. Returns
/// `{ok:true, thread_id, receipts:[{user, message_id, horizon}]}` or
/// `{ok:false}`. Empty `thread_id` is rejected before any network.
pub fn receipts_json(thread_id: &str) -> String {
    if thread_id.trim().is_empty() {
        return err_json("arg", "empty thread_id");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let receipts = ost::api::read_receipts_data(&client, thread_id.trim())
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = receipts.iter().map(receipt_to_json).collect();
            Ok(json!({"ok": true, "thread_id": thread_id.trim(), "receipts": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("receipts", e),
    }
}

// ---------------------------------------------------------------------------
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

/// Media LRU caps: 64 URLs, 32 MB of envelopes. Chat media URLs are
/// content-addressed object views (immutable per URL), so a session
/// cache keyed by exact URL is behavior-preserving.
pub const MEDIA_CACHE_MAX_ENTRIES: usize = 64;
pub const MEDIA_CACHE_MAX_BYTES: usize = 32 * 1024 * 1024;

struct MediaCache {
    map: HashMap<String, String>,
    order: VecDeque<String>,
    bytes: usize,
}

impl MediaCache {
    fn new() -> Self {
        Self {
            map: HashMap::new(),
            order: VecDeque::new(),
            bytes: 0,
        }
    }

    fn get(&mut self, url: &str) -> Option<String> {
        let hit = self.map.get(url)?.clone();
        self.touch(url);
        Some(hit)
    }

    fn put(&mut self, url: String, envelope: String) {
        if self.map.contains_key(&url) {
            self.touch(&url);
            return;
        }
        let size = url.len() + envelope.len();
        if size > MEDIA_CACHE_MAX_BYTES {
            return; // single item over cap: never cache
        }
        while self.map.len() >= MEDIA_CACHE_MAX_ENTRIES
            || self.bytes + size > MEDIA_CACHE_MAX_BYTES
        {
            match self.order.pop_front() {
                Some(oldest) => {
                    if let Some(ev) = self.map.remove(&oldest) {
                        self.bytes -= oldest.len() + ev.len();
                    }
                }
                None => break,
            }
        }
        self.order.push_back(url.clone());
        self.bytes += size;
        self.map.insert(url, envelope);
    }

    fn touch(&mut self, url: &str) {
        if let Some(pos) = self.order.iter().position(|u| u == url) {
            self.order.remove(pos);
            self.order.push_back(url.to_string());
        }
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.map.len()
    }

    #[cfg(test)]
    fn contains(&self, url: &str) -> bool {
        self.map.contains_key(url)
    }
}

fn media_cache() -> &'static Mutex<MediaCache> {
    static M: OnceLock<Mutex<MediaCache>> = OnceLock::new();
    M.get_or_init(|| Mutex::new(MediaCache::new()))
}

/// Fetch one inline-image URL as `{ok:true, data_base64, content_type?}`.
/// Microsoft media hosts attach the Skype token; public hosts fetch without
/// auth (see `ost::api::media`). Empty/non-https URLs are rejected before
/// any network. Requires sign-in for auth'd hosts; unsigned yields
/// `{ok:false}`. Successes are LRU-cached by URL (64 URLs / 32 MB).
/// Caller frees.
pub fn media_fetch_json(url: &str) -> String {
    let u = url.trim();
    if u.is_empty() {
        return err_json("arg", "empty url");
    }
    if !u.starts_with("https://") {
        return err_json("arg", "media URL must be https");
    }
    if let Some(hit) = media_cache()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(u)
    {
        return hit;
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
        Ok(s) => {
            // Cache only successes (same bytes the fetch returned).
            media_cache()
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .put(u.to_string(), s.clone());
            s
        }
        Err(e) => err_json("media", e),
    }
}

// ---------------------------------------------------------------------------
// Shared files (om-shared lane: Graph driveItems for chats + channels)
// ---------------------------------------------------------------------------

fn shared_file_to_json(f: &ost::api::SharedFile) -> serde_json::Value {
    json!({
        "id": f.id,
        "name": f.name,
        "size": f.size,
        "mime": f.mime,
        "web_url": f.web_url,
        "download_url": f.download_url,
        "drive_id": f.drive_id,
        "created": f.created,
        "modified": f.modified,
        "sender": f.sender,
        "is_folder": f.is_folder,
        "attachment_id": f.attachment_id,
        "share_url": f.share_url,
    })
}

/// Shared files for one chat/channel as JSON. Requires sign-in; unsigned
/// yields `{ok:false}`. Empty `chat_id` is rejected before any network.
/// Default shape (stable): folders filtered, same as `_opts(..., false)`.
pub fn files_json(chat_id: &str, limit: usize) -> String {
    files_json_opts(chat_id, limit, false)
}

/// Shared files, optionally including folders (om-i5-folders).
/// `include_folders=true` keeps folder driveItems; each item carries
/// `is_folder`, and folders drill in via [`files_children_json`].
/// Returns `{ok:true, chat_id, files:[...]}`.
pub fn files_json_opts(chat_id: &str, limit: usize, include_folders: bool) -> String {
    if chat_id.trim().is_empty() {
        return err_json("arg", "empty chat_id");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let files =
                ost::api::list_chat_files_data_opts(&client, chat_id, limit, include_folders)
                    .await
                    .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = files.iter().map(shared_file_to_json).collect();
            Ok(json!({"ok": true, "chat_id": chat_id, "files": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("files", e),
    }
}

/// One folder's children by drive+item id (om-i5-folders). Files AND
/// subfolders, unfiltered; folders carry `is_folder:true` and drill in
/// via this same call. Empty ids are rejected before any network.
/// Returns `{ok:true, drive_id, item_id, files:[...]}`.
pub fn files_children_json(drive_id: &str, item_id: &str, limit: usize) -> String {
    if drive_id.trim().is_empty() {
        return err_json("arg", "empty drive_id");
    }
    if item_id.trim().is_empty() {
        return err_json("arg", "empty item_id");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let files = ost::api::list_folder_children_data(&client, drive_id, item_id, limit)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = files.iter().map(shared_file_to_json).collect();
            Ok(
                json!({"ok": true, "drive_id": drive_id, "item_id": item_id, "files": items})
                    .to_string(),
            )
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("files_children", e),
    }
}

/// Search the signed-in user's OneDrive by name/content (om-jb-filesearch).
/// One `$top` window (limit clamped 1..=25); rows reuse the Shared tab
/// projection. Empty queries are rejected before any network.
/// Returns `{ok:true, query, files:[...]}`.
pub fn file_search_json(query: &str, limit: usize) -> String {
    if query.trim().is_empty() {
        return err_json("arg", "empty query");
    }
    let limit = ost::api::clamp_limit(limit);
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let files = ost::api::search_files_data(&client, query, limit)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = files.iter().map(shared_file_to_json).collect();
            Ok(json!({"ok": true, "query": query, "files": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("file_search", e),
    }
}

/// Search the directory for people by display name (om-jb-filesearch).
/// One `$top` window (limit clamped 1..=25); rows reuse the roster
/// projection with empty roles (directory hits carry no team role).
/// Empty queries are rejected before any network.
/// Returns `{ok:true, query, people:[...]}`.
pub fn people_search_json(query: &str, limit: usize) -> String {
    if query.trim().is_empty() {
        return err_json("arg", "empty query");
    }
    let limit = ost::api::clamp_limit(limit);
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let people = ost::api::search_people_data(&client, query, limit)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = people.iter().map(team_member_to_json).collect();
            Ok(json!({"ok": true, "query": query, "people": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("people_search", e),
    }
}

/// Upload a local file to a chat/channel and post it as a `reference`
/// attachment. Files <=4 MB use one simple PUT; larger files use a
/// resumable upload session (ost routes on size). Per-fragment progress
/// lands in the upload-progress store (see [`upload_progress_json`]).
/// Empty args are rejected before any network. Returns `{ok:true, file}`.
pub fn files_upload_json(chat_id: &str, path: &str) -> String {
    if chat_id.trim().is_empty() {
        return err_json("arg", "empty chat_id");
    }
    if path.trim().is_empty() {
        return err_json("arg", "empty path");
    }
    upload_progress_reset();
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let file = ost::api::upload_file_data_with_progress(
                &client,
                chat_id,
                path,
                Some(&upload_progress_report),
            )
            .await
            .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "file": shared_file_to_json(&file)}).to_string())
        })
    };
    let out = match run() {
        Ok(s) => s,
        Err(e) => err_json("files_upload", e),
    };
    upload_progress_finish();
    out
}

// ---------------------------------------------------------------------------
// Upload progress (om-i4-bigup: polled % while the Swift spinner runs)
// ---------------------------------------------------------------------------

/// Process-wide upload progress: `files_upload_json` reports per-fragment
/// `(sent, total)` here; Swift polls [`upload_progress_json`] on a timer
/// while its spinner runs. One upload at a time per process (the composer
/// uploads sequentially; a concurrent Shared-tab upload steals the gauge).
static UPLOAD_SENT: AtomicU64 = AtomicU64::new(0);
static UPLOAD_TOTAL: AtomicU64 = AtomicU64::new(0);
static UPLOAD_ACTIVE: AtomicBool = AtomicBool::new(false);

fn upload_progress_reset() {
    UPLOAD_SENT.store(0, Ordering::Relaxed);
    UPLOAD_TOTAL.store(0, Ordering::Relaxed);
    UPLOAD_ACTIVE.store(true, Ordering::Relaxed);
}

fn upload_progress_report(sent: u64, total: u64) {
    UPLOAD_SENT.store(sent, Ordering::Relaxed);
    UPLOAD_TOTAL.store(total, Ordering::Relaxed);
}

fn upload_progress_finish() {
    UPLOAD_ACTIVE.store(false, Ordering::Relaxed);
}

/// Whole-percent progress, clamped to 0..=100 (unknown total reads 0).
pub fn upload_percent(sent: u64, total: u64) -> u64 {
    if total == 0 {
        return 0;
    }
    (sent.saturating_mul(100) / total).min(100)
}

/// Current upload progress as JSON (pure read, no network, never fails):
/// `{ok:true, uploaded, total, percent, active}`. `active` is true only
/// while a `files_upload_json` call is in flight.
pub fn upload_progress_json() -> String {
    let sent = UPLOAD_SENT.load(Ordering::Relaxed);
    let total = UPLOAD_TOTAL.load(Ordering::Relaxed);
    json!({
        "ok": true,
        "uploaded": sent,
        "total": total,
        "percent": upload_percent(sent, total),
        "active": UPLOAD_ACTIVE.load(Ordering::Relaxed),
    })
    .to_string()
}

/// Create a view-only sharing link for one driveItem (Graph
/// createLink, om-i1-links). `scope` is `organization` (default) or
/// `anonymous`; blank/unknown normalizes to `organization` in ost.
/// Empty ids are rejected before any network.
/// Returns `{ok:true, link, scope}`.
pub fn files_link_json(drive_id: &str, item_id: &str, scope: &str) -> String {
    if drive_id.trim().is_empty() {
        return err_json("arg", "empty drive_id");
    }
    if item_id.trim().is_empty() {
        return err_json("arg", "empty item_id");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let link = ost::api::create_link_data(&client, drive_id, item_id, scope)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "link": link.url, "scope": link.scope}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("files_link", e),
    }
}
/// Rename one driveItem (PATCH name). Empty args are rejected before
/// any network. Returns `{ok:true, file:{...}}`.
pub fn files_rename_json(drive_id: &str, item_id: &str, new_name: &str) -> String {
    if drive_id.trim().is_empty() {
        return err_json("arg", "empty drive_id");
    }
    if item_id.trim().is_empty() {
        return err_json("arg", "empty item_id");
    }
    if new_name.trim().is_empty() {
        return err_json("arg", "empty new_name");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let file = ost::api::rename_file_data(&client, drive_id, item_id, new_name)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "file": shared_file_to_json(&file)}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("files_rename", e),
    }
}

/// Move one driveItem to another folder in the same drive (PATCH
/// parentReference). Returns `{ok:true, file:{...}}`.
pub fn files_move_json(drive_id: &str, item_id: &str, dest_folder_id: &str) -> String {
    if drive_id.trim().is_empty() {
        return err_json("arg", "empty drive_id");
    }
    if item_id.trim().is_empty() {
        return err_json("arg", "empty item_id");
    }
    if dest_folder_id.trim().is_empty() {
        return err_json("arg", "empty dest_folder_id");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let file = ost::api::move_file_data(&client, drive_id, item_id, dest_folder_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "file": shared_file_to_json(&file)}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("files_move", e),
    }
}

/// Copy one driveItem to another folder in the same drive (server-side
/// async: Graph answers 202 + monitor URL). `new_name` (None/empty) keeps
/// the source name. Returns `{ok:true, monitor}`.
pub fn files_copy_json(
    drive_id: &str,
    item_id: &str,
    dest_folder_id: &str,
    new_name: Option<&str>,
) -> String {
    if drive_id.trim().is_empty() {
        return err_json("arg", "empty drive_id");
    }
    if item_id.trim().is_empty() {
        return err_json("arg", "empty item_id");
    }
    if dest_folder_id.trim().is_empty() {
        return err_json("arg", "empty dest_folder_id");
    }
    let name = new_name.filter(|n| !n.trim().is_empty());
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let monitor =
                ost::api::copy_file_data(&client, drive_id, item_id, dest_folder_id, name)
                    .await
                    .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "monitor": monitor}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("files_copy", e),
    }
}

/// Delete one driveItem (DELETE). Returns `{ok:true, id}`.
pub fn files_delete_json(drive_id: &str, item_id: &str) -> String {
    if drive_id.trim().is_empty() {
        return err_json("arg", "empty drive_id");
    }
    if item_id.trim().is_empty() {
        return err_json("arg", "empty item_id");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            ost::api::delete_file_data(&client, drive_id, item_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "id": item_id}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("files_delete", e),
    }
}

/// Download one driveItem's content to `dest`. Empty args are rejected
/// before any network. Returns `{ok:true, path, bytes}`.
pub fn files_download_json(drive_id: &str, item_id: &str, dest: &str) -> String {
    if drive_id.trim().is_empty() {
        return err_json("arg", "empty drive_id");
    }
    if item_id.trim().is_empty() {
        return err_json("arg", "empty item_id");
    }
    if dest.trim().is_empty() {
        return err_json("arg", "empty dest");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let n = ost::api::download_file_data(&client, drive_id, item_id, dest)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "path": dest, "bytes": n}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("files_download", e),
    }
}

// ---------------------------------------------------------------------------
// File versions (om-i2-versions lane: Graph driveItemVersion history)
// ---------------------------------------------------------------------------

fn file_version_to_json(v: &ost::api::FileVersion) -> serde_json::Value {
    json!({
        "id": v.id,
        "size": v.size,
        "modified": v.modified,
        "modified_by": v.modified_by,
    })
}

/// Version history for one driveItem as JSON. Requires sign-in; unsigned
/// yields `{ok:false}`. Empty ids are rejected before any network.
/// Returns `{ok:true, drive_id, item_id, versions:[...]}` (newest first).
pub fn file_versions_json(drive_id: &str, item_id: &str) -> String {
    if drive_id.trim().is_empty() {
        return err_json("arg", "empty drive_id");
    }
    if item_id.trim().is_empty() {
        return err_json("arg", "empty item_id");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let versions = ost::api::list_file_versions_data(&client, drive_id, item_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = versions.iter().map(file_version_to_json).collect();
            Ok(json!({"ok": true, "drive_id": drive_id, "item_id": item_id, "versions": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("file_versions", e),
    }
}

/// Restore one version as current (Graph `restoreVersion` action).
/// Returns `{ok:true, drive_id, item_id, version_id}`.
pub fn file_version_restore_json(drive_id: &str, item_id: &str, version_id: &str) -> String {
    if drive_id.trim().is_empty() {
        return err_json("arg", "empty drive_id");
    }
    if item_id.trim().is_empty() {
        return err_json("arg", "empty item_id");
    }
    if version_id.trim().is_empty() {
        return err_json("arg", "empty version_id");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            ost::api::restore_file_version_data(&client, drive_id, item_id, version_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "drive_id": drive_id, "item_id": item_id, "version_id": version_id}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("file_version_restore", e),
    }
}

/// Download one old version's content to `dest`.
/// Returns `{ok:true, path, bytes}`.
pub fn file_version_download_json(
    drive_id: &str,
    item_id: &str,
    version_id: &str,
    dest: &str,
) -> String {
    if drive_id.trim().is_empty() {
        return err_json("arg", "empty drive_id");
    }
    if item_id.trim().is_empty() {
        return err_json("arg", "empty item_id");
    }
    if version_id.trim().is_empty() {
        return err_json("arg", "empty version_id");
    }
    if dest.trim().is_empty() {
        return err_json("arg", "empty dest");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let n = ost::api::download_file_version_data(&client, drive_id, item_id, version_id, dest)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "path": dest, "bytes": n}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("file_version_download", e),
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
// MRI resolution (om-steal-ids lane)
// ---------------------------------------------------------------------------

// Ported from weirdapps teams-access `src/commands/resolve-mri.ts` (MIT):
// translate a Teams MRI `8:orgid:<aad-oid>` to {id, email, displayName} via
// Graph /users/{aad-oid}. ost has no equivalent — its call slot shows raw
// MRIs and presence takes user ids the UI can't derive. `mail` is null for
// guests (same as upstream).
fn resolve_envelope(id: &str, email: Option<&str>, display_name: &str) -> String {
    json!({
        "ok": true,
        "id": id,
        "email": email,
        "display_name": display_name,
    })
    .to_string()
}

/// AAD object id from a Teams MRI. Mirrors upstream `MRI_RE`
/// (`/^8:orgid:([A-Za-z0-9-]+)$/`): only orgid MRIs resolve via Graph;
/// skypeids/visitor/federated forms are None (caller reports `arg`).
fn mri_to_oid(mri: &str) -> Option<&str> {
    let oid = mri.strip_prefix("8:orgid:")?;
    if oid.is_empty() || !oid.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return None;
    }
    Some(oid)
}

/// True when a TeamsClient failure is a Graph 404 (unknown user). Upstream
/// surfaces 404 distinctly so callers can mark permanent_fail; ost's
/// `check_response` folds it into `anyhow` text, so match the status prefix.
fn is_not_found(detail: &str) -> bool {
    detail.contains("HTTP 404")
}

/// Resolve a Teams MRI to a Graph user. Empty/non-orgid `mri` is rejected
/// before any network (`arg`); unknown users yield `not_found` (permanent,
/// don't retry); anything else is `resolve_mri`.
/// `{ok:true, id, email|null, display_name}` or `{ok:false}`.
pub fn resolve_mri_json(mri: &str) -> String {
    let m = mri.trim();
    if m.is_empty() {
        return err_json("arg", "empty mri");
    }
    let oid = match mri_to_oid(m) {
        Some(o) => o.to_string(),
        None => {
            return err_json(
                "arg",
                format!("invalid MRI (want 8:orgid:<aad-oid>): {}", m),
            )
        }
    };
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let resp = client
                .graph_get(&format!("/users/{}", oid))
                .await
                .map_err(|e| format!("{:#}", e))?;
            #[derive(serde::Deserialize)]
            struct U {
                id: String,
                mail: Option<String>,
                #[serde(rename = "displayName")]
                display_name: String,
            }
            let u: U = resp
                .json()
                .await
                .map_err(|e| format!("Failed to parse user response: {}", e))?;
            Ok(resolve_envelope(&u.id, u.mail.as_deref(), &u.display_name))
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) if is_not_found(&e) => err_json("not_found", e),
        Err(e) => err_json("resolve_mri", e),
    }
}

// ---------------------------------------------------------------------------
// Reminders (om-remind lane: Microsoft To Do via Graph /me/todo)
// ---------------------------------------------------------------------------

fn todo_list_to_json(l: &ost::api::TodoListInfo) -> serde_json::Value {
    json!({
        "id": l.id,
        "name": l.name,
        "wellknown": l.wellknown,
    })
}

fn todo_task_to_json(t: &ost::api::TodoTaskInfo) -> serde_json::Value {
    json!({
        "id": t.id,
        "title": t.title,
        "status": t.status,
        "importance": t.importance,
        "due": t.due,
        "reminder": t.reminder,
        "completed": t.completed,
    })
}

/// To Do lists as JSON. Requires sign-in; unsigned yields `{ok:false}`.
pub fn reminders_json() -> String {
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let lists = ost::api::list_todo_lists_data(&client)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = lists.iter().map(todo_list_to_json).collect();
            Ok(json!({"ok": true, "lists": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("reminders", e),
    }
}

/// Reject a Graph path-segment id before any network. Mirrors the ost
/// guard so Swift gets `arg` errors without a client build.
fn todo_id_ok(what: &str, id: &str) -> Result<(), String> {
    if id.trim().is_empty() {
        return Err(err_json("arg", format!("empty {}", what)));
    }
    if id.contains('/')
        || id.contains('?')
        || id.contains('#')
        || id.chars().any(|c| c.is_whitespace())
    {
        return Err(err_json(
            "arg",
            format!("{} must not contain '/', '?', '#' or whitespace", what),
        ));
    }
    Ok(())
}

/// Tasks for one To Do list as JSON. Requires sign-in; unsigned yields
/// `{ok:false}`. Bad `list_id` is rejected before any network.
pub fn reminder_tasks_json(list_id: &str, limit: usize) -> String {
    if let Err(e) = todo_id_ok("list_id", list_id) {
        return e;
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let tasks = ost::api::list_todo_tasks_data(&client, list_id, limit)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = tasks.iter().map(todo_task_to_json).collect();
            Ok(json!({"ok": true, "list_id": list_id, "tasks": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("reminder_tasks", e),
    }
}

/// Create one task in a list. Returns `{ok:true, task}` or `{ok:false}`.
/// Empty `list_id`/`title` are rejected before any network.
pub fn reminder_add_json(list_id: &str, title: &str) -> String {
    if let Err(e) = todo_id_ok("list_id", list_id) {
        return e;
    }
    if title.trim().is_empty() {
        return err_json("arg", "empty title");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let task = ost::api::create_todo_task_data(&client, list_id, title)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "task": todo_task_to_json(&task)}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("reminder_add", e),
    }
}

/// Mark one task completed. Returns `{ok:true, task}` or `{ok:false}`.
/// Bad ids are rejected before any network.
pub fn reminder_done_json(list_id: &str, task_id: &str) -> String {
    if let Err(e) = todo_id_ok("list_id", list_id) {
        return e;
    }
    if let Err(e) = todo_id_ok("task_id", task_id) {
        return e;
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let task = ost::api::complete_todo_task_data(&client, list_id, task_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "task": todo_task_to_json(&task)}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("reminder_done", e),
    }
}

// ---------------------------------------------------------------------------
// Meetings (om-meet-join lane: upcoming via Graph calendarView + join parse)
// ---------------------------------------------------------------------------

fn meeting_to_json(m: &ost::api::MeetingInfo) -> serde_json::Value {
    json!({
        "id": m.id,
        "subject": m.subject,
        "start": m.start,
        "end": m.end,
        "join_url": m.join_url,
        "organizer": m.organizer,
        "is_online": m.is_online,
    })
}

/// Upcoming meetings as JSON. Requires sign-in; unsigned yields `{ok:false}`.
pub fn meetings_json(limit: usize) -> String {
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let meetings = ost::api::list_upcoming_meetings_data(&client, limit)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = meetings.iter().map(meeting_to_json).collect();
            Ok(json!({"ok": true, "meetings": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("meetings", e),
    }
}

/// Classify a pasted join string. Pure (no network, no sign-in needed).
/// Returns `{ok:true, target:{kind,thread_id?,meeting_id?,url}}`.
pub fn meeting_join_parse_json(raw: &str) -> String {
    let t = ost::api::parse_join_url(raw);
    json!({
        "ok": true,
        "target": {
            "kind": t.kind,
            "thread_id": t.thread_id,
            "meeting_id": t.meeting_id,
            "url": t.url,
        },
    })
    .to_string()
}

// ---------------------------------------------------------------------------
// Notes (om-notes lane: OneNote read + paragraph append)
// ---------------------------------------------------------------------------

fn notebook_to_json(n: &ost::api::NotebookInfo) -> serde_json::Value {
    json!({
        "id": n.id,
        "name": n.name,
    })
}

fn note_page_meta_to_json(p: &ost::api::PageInfo) -> serde_json::Value {
    json!({
        "id": p.id,
        "title": p.title,
        "updated": p.updated,
    })
}

fn note_section_to_json(s: &ost::api::SectionInfo) -> serde_json::Value {
    let pages: Vec<_> = s.pages.iter().map(note_page_meta_to_json).collect();
    json!({
        "id": s.id,
        "name": s.name,
        "pages": pages,
    })
}

/// Normalize the optional group scope: `None`/blank reads the user's own
/// OneNote; otherwise the id must be path-safe (no `/`, no whitespace).
fn notes_group(group_id: Option<&str>) -> Result<Option<String>, String> {
    match group_id.map(str::trim) {
        None | Some("") => Ok(None),
        Some(g) => {
            if g.contains('/') || g.chars().any(|c| c.is_whitespace()) {
                return Err("group_id must not contain '/' or whitespace".to_string());
            }
            Ok(Some(g.to_string()))
        }
    }
}

/// List OneNote notebooks as JSON. `group_id` (`None`/blank = the user's
/// own) reads the M365 group (team) notebooks instead. Requires sign-in.
pub fn notes_json(group_id: Option<&str>) -> String {
    let group = match notes_group(group_id) {
        Ok(g) => g,
        Err(e) => return err_json("arg", e),
    };
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let notebooks = ost::api::list_notebooks_data(&client, group.as_deref())
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = notebooks.iter().map(notebook_to_json).collect();
            Ok(json!({"ok": true, "notebooks": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("notes", e),
    }
}

/// One notebook's sections, each with its pages. Empty `notebook_id` is
/// rejected before any network.
pub fn note_sections_json(notebook_id: &str, group_id: Option<&str>) -> String {
    if notebook_id.trim().is_empty() {
        return err_json("arg", "empty notebook_id");
    }
    let group = match notes_group(group_id) {
        Ok(g) => g,
        Err(e) => return err_json("arg", e),
    };
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let sections = ost::api::list_notebook_sections_data(
                &client,
                notebook_id.trim(),
                group.as_deref(),
            )
            .await
            .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = sections.iter().map(note_section_to_json).collect();
            Ok(json!({"ok": true, "sections": items}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("note_sections", e),
    }
}

/// One page's HTML content. Empty `page_id` is rejected before any network.
pub fn note_page_json(page_id: &str, group_id: Option<&str>) -> String {
    if page_id.trim().is_empty() {
        return err_json("arg", "empty page_id");
    }
    let group = match notes_group(group_id) {
        Ok(g) => g,
        Err(e) => return err_json("arg", e),
    };
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let page = ost::api::read_note_page_data(&client, page_id.trim(), group.as_deref())
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({
                "ok": true,
                "id": page.id,
                "title": page.title,
                "html": page.html,
            })
            .to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("note_page", e),
    }
}

/// Append one plain-text paragraph to a page. Empty `page_id`/`text` are
/// rejected before any network. Returns `{ok:true, id}`.
pub fn note_append_json(page_id: &str, text: &str, group_id: Option<&str>) -> String {
    if page_id.trim().is_empty() {
        return err_json("arg", "empty page_id");
    }
    if text.trim().is_empty() {
        return err_json("arg", "empty text");
    }
    let group = match notes_group(group_id) {
        Ok(g) => g,
        Err(e) => return err_json("arg", e),
    };
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            ost::api::append_note_paragraph_data(
                &client,
                page_id.trim(),
                text,
                group.as_deref(),
            )
            .await
            .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "id": page_id.trim()}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("note_append", e),
    }
}

// ---------------------------------------------------------------------------
// Trouter event channel
// ---------------------------------------------------------------------------

struct TrouterState {
    rt: &'static tokio::runtime::Runtime,
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
    match Config::load_cached() {
        Ok(cfg) => match cfg.get_skype_token() {
            Some(t) if !t.is_expired() => {}
            _ => return -2,
        },
        Err(_) => return -2,
    }
    // UI-driven signaling: the bg loop must not auto-answer incoming
    // calls (ost honors this; invitations still reach event_hub).
    std::env::set_var("TEAMS_MANUAL_CALLS", "1");
    let rt = match rt() {
        Ok(r) => r,
        Err(_) => return -3,
    };
    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();
    let task = rt.spawn(async move {
        let _ = ost::trouter::connect_and_run().await;
    });
    let driver = std::thread::Builder::new()
        .name("ostmac-trouter".to_string())
        .spawn(move || {
            let _ = rt.block_on(async move {
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

/// Max events drained per poll. 256 of the 1024 hub cap: a full burst
/// clears in 4 ticks instead of 16; `backlog` tells the host more waits.
pub const TROUTER_DRAIN_MAX: usize = 256;

/// Drain queued Trouter events as `{ok:true, events:[...], backlog:n}`
/// (raw JSON strings; `backlog` = still queued after this drain).
pub fn trouter_poll_json() -> String {
    let events = ost::event_hub::drain(TROUTER_DRAIN_MAX);
    let backlog = ost::event_hub::len();
    let parsed: Vec<serde_json::Value> = events
        .iter()
        .map(|e| serde_json::from_str(e).unwrap_or(json!({"raw": e})))
        .collect();
    json!({"ok": true, "events": parsed, "backlog": backlog}).to_string()
}

/// Blocking variant of [`trouter_poll_json`]: waits up to `timeout_ms`
/// for the first event instead of returning empty immediately, so the
/// host can sleep instead of waking on a fixed timer. Same envelope.
/// `timeout_ms == 0` polls without waiting.
pub fn trouter_poll_wait_json(timeout_ms: u64) -> String {
    let events = ost::event_hub::drain_wait(TROUTER_DRAIN_MAX, timeout_ms);
    let backlog = ost::event_hub::len();
    let parsed: Vec<serde_json::Value> = events
        .iter()
        .map(|e| serde_json::from_str(e).unwrap_or(json!({"raw": e})))
        .collect();
    json!({"ok": true, "events": parsed, "backlog": backlog}).to_string()
}

/// Drain queued Trouter events as typed realtime messages.
///
/// `{ok:true, messages:[{chat_id,id,sender,sender_id?,text,time,
/// is_edit,edited_id?,message_type,reactions?,raw}], resync:bool, skipped:n,
/// calls:[{kind,call_id,peer,peer_name,detail?}],
/// typing:[{chat_id,sender,sender_id?,time}],
/// roster:[{meeting_id,id,name,speaking?,muted?,present?}]}`.
/// `resync` is true when a `trouter.message_loss` frame was seen: the UI
/// must re-fetch visible conversations (push had a gap). `skipped` counts
/// non-message frames (handshake, presence…). `calls` carries incoming
/// invitations / remote ends (also recorded in the call slot). `typing`
/// carries typing indicators (held per thread with a timeout, never bubbles).
/// `roster` carries meeting-roster snapshots (upserted in place by id,
/// never a list refresh). `backlog` counts events still queued after
/// this drain (256/tick of the 1024 hub cap).
/// NOTE: drains the same queue as [`trouter_poll_json`] — use one consumer.
pub fn trouter_poll_typed_json() -> String {
    let events = ost::event_hub::drain(TROUTER_DRAIN_MAX);
    typed_envelope(events)
}

/// Blocking variant of [`trouter_poll_typed_json`]: waits up to
/// `timeout_ms` for the first event instead of returning empty
/// immediately. Same envelope. `timeout_ms == 0` polls without waiting.
pub fn trouter_poll_typed_wait_json(timeout_ms: u64) -> String {
    let events = ost::event_hub::drain_wait(TROUTER_DRAIN_MAX, timeout_ms);
    typed_envelope(events)
}

/// Build the typed realtime envelope for one drained batch.
fn typed_envelope(events: Vec<String>) -> String {
    let backlog = ost::event_hub::len();
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
    let call_events = calls::scan_values(&values);
    json!({
        "ok": true,
        "messages": batch.messages,
        "resync": batch.resync,
        "skipped": batch.skipped,
        "calls": call_events,
        "typing": batch.typing,
        "roster": batch.roster,
        "backlog": backlog,
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

/// Browser-capture start JSON (`session`, `authorize_url`, `redirect_uri`).
/// See [`browser_auth::authcode_start_json`]. No network. Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_authcode_start() -> *mut c_char {
    string_to_c(browser_auth::authcode_start_json())
}

/// Browser-capture complete: `session` + intercepted callback URL.
/// See [`browser_auth::authcode_complete_json`]. Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_authcode_complete(
    session: *const c_char,
    callback: *const c_char,
) -> *mut c_char {
    let s = match cstr_to_string(session) {
        Ok(v) => v,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(callback) {
        Ok(c) => string_to_c(browser_auth::authcode_complete_json(&s, &c)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Drop one pending browser session. See [`browser_auth::authcode_cancel_json`].
#[no_mangle]
pub extern "C" fn ostmac_authcode_cancel(session: *const c_char) -> *mut c_char {
    match cstr_to_string(session) {
        Ok(s) => string_to_c(browser_auth::authcode_cancel_json(&s)),
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

/// Create a 1:1 chat with one user ref (AAD id or UPN). See
/// [`chat_create_one_to_one_json`]. Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_chat_create_one_to_one(user: *const c_char) -> *mut c_char {
    match cstr_to_string(user) {
        Ok(u) => string_to_c(chat_create_one_to_one_json(&u)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Joined-teams JSON (requires sign-in). See [`teams_json`].
#[no_mangle]
pub extern "C" fn ostmac_teams() -> *mut c_char {
    string_to_c(teams_json())
}

/// Create one channel in a team. `description` may be NULL (no
/// description). See [`channel_create_json`]. Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_channel_create(
    team_id: *const c_char,
    name: *const c_char,
    description: *const c_char,
) -> *mut c_char {
    let id = match cstr_to_string(team_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let nm = match cstr_to_string(name) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match opt_cstr_to_string(description) {
        Ok(d) => string_to_c(channel_create_json(&id, &nm, d.as_deref())),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Join one team by id (requires sign-in). See [`team_join_json`].
#[no_mangle]
pub extern "C" fn ostmac_team_join(team_id: *const c_char) -> *mut c_char {
    match cstr_to_string(team_id) {
        Ok(id) => string_to_c(team_join_json(&id)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Create one standard team (async Graph POST, requires sign-in).
/// `description` may be NULL (no description). See
/// [`team_create_json`]. Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_team_create(
    name: *const c_char,
    description: *const c_char,
) -> *mut c_char {
    let nm = match cstr_to_string(name) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match opt_cstr_to_string(description) {
        Ok(d) => string_to_c(team_create_json(&nm, d.as_deref())),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// One team's roster JSON (requires sign-in). See [`team_members_json`].
#[no_mangle]
pub extern "C" fn ostmac_team_members(team_id: *const c_char) -> *mut c_char {
    match cstr_to_string(team_id) {
        Ok(t) => string_to_c(team_members_json(&t)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// One channel's pinned tabs JSON (read-only). See [`tabs_json`].
#[no_mangle]
pub extern "C" fn ostmac_tabs(channel_id: *const c_char) -> *mut c_char {
    match cstr_to_string(channel_id) {
        Ok(id) => string_to_c(tabs_json(&id)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Add one user to a team. See [`team_member_add_json`].
/// `owner` nonzero grants the owner role.
#[no_mangle]
pub extern "C" fn ostmac_team_member_add(
    team_id: *const c_char,
    user: *const c_char,
    owner: c_int,
) -> *mut c_char {
    let team = match cstr_to_string(team_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(user) {
        Ok(u) => string_to_c(team_member_add_json(&team, &u, owner != 0)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Remove one membership from a team. See [`team_member_remove_json`].
#[no_mangle]
pub extern "C" fn ostmac_team_member_remove(
    team_id: *const c_char,
    member_id: *const c_char,
) -> *mut c_char {
    let team = match cstr_to_string(team_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(member_id) {
        Ok(m) => string_to_c(team_member_remove_json(&team, &m)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
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

/// Teams message search, one `from`/`size` window. See [`search_json`].
/// Negative `from` clamps to 0; non-positive `size` means 25.
#[no_mangle]
pub extern "C" fn ostmac_search(
    query: *const c_char,
    from: c_int,
    size: c_int,
) -> *mut c_char {
    let from = if from < 0 { 0 } else { from as usize };
    let size = if size <= 0 { 25 } else { size as usize };
    match cstr_to_string(query) {
        Ok(q) => string_to_c(search_json(&q, from, size)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Post one quote reply to a chat message. See [`reply_json`].
#[no_mangle]
pub extern "C" fn ostmac_reply(
    chat_id: *const c_char,
    parent_id: *const c_char,
    parent_sender: *const c_char,
    parent_text: *const c_char,
    text: *const c_char,
) -> *mut c_char {
    let id = match cstr_to_string(chat_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let parent = match cstr_to_string(parent_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let sender = match cstr_to_string(parent_sender) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let snippet = match cstr_to_string(parent_text) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(text) {
        Ok(t) => string_to_c(reply_json(&id, &parent, &sender, &snippet, &t)),
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

/// Add one emoji reaction to a message. See [`react_json`].
#[no_mangle]
pub extern "C" fn ostmac_react(
    chat_id: *const c_char,
    message_id: *const c_char,
    emoji: *const c_char,
) -> *mut c_char {
    let id = match cstr_to_string(chat_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let mid = match cstr_to_string(message_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(emoji) {
        Ok(e) => string_to_c(react_json(&id, &mid, &e)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Remove one emoji reaction from a message. See [`react_remove_json`].
#[no_mangle]
pub extern "C" fn ostmac_react_remove(
    chat_id: *const c_char,
    message_id: *const c_char,
    emoji: *const c_char,
) -> *mut c_char {
    let id = match cstr_to_string(chat_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let mid = match cstr_to_string(message_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(emoji) {
        Ok(e) => string_to_c(react_remove_json(&id, &mid, &e)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Edit one own message. See [`edit_json`].
#[no_mangle]
pub extern "C" fn ostmac_edit(
    chat_id: *const c_char,
    message_id: *const c_char,
    text: *const c_char,
) -> *mut c_char {
    let id = match cstr_to_string(chat_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let mid = match cstr_to_string(message_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(text) {
        Ok(t) => string_to_c(edit_json(&id, &mid, &t)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Delete one own message. See [`delete_json`].
#[no_mangle]
pub extern "C" fn ostmac_delete(
    chat_id: *const c_char,
    message_id: *const c_char,
) -> *mut c_char {
    let id = match cstr_to_string(chat_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(message_id) {
        Ok(m) => string_to_c(delete_json(&id, &m)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Leave one group chat. See [`leave_json`].
#[no_mangle]
pub extern "C" fn ostmac_leave(chat_id: *const c_char) -> *mut c_char {
    match cstr_to_string(chat_id) {
        Ok(t) => string_to_c(leave_json(&t)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Mark one conversation read up to a message. See [`mark_read_json`].
#[no_mangle]
pub extern "C" fn ostmac_mark_read(
    chat_id: *const c_char,
    message_id: *const c_char,
) -> *mut c_char {
    let id = match cstr_to_string(chat_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(message_id) {
        Ok(m) => string_to_c(mark_read_json(&id, &m)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Peer read positions for one thread. See [`receipts_json`].
#[no_mangle]
pub extern "C" fn ostmac_receipts(thread_id: *const c_char) -> *mut c_char {
    match cstr_to_string(thread_id) {
        Ok(t) => string_to_c(receipts_json(&t)),
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

/// Shared files JSON for one chat/channel. See [`files_json`].
#[no_mangle]
pub extern "C" fn ostmac_files(chat_id: *const c_char, limit: c_int) -> *mut c_char {
    let lim = if limit <= 0 { 20 } else { limit as usize };
    match cstr_to_string(chat_id) {
        Ok(id) => string_to_c(files_json(&id, lim)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Shared files, optionally including folders. See [`files_json_opts`].
/// `include_folders` nonzero keeps folder driveItems (each `is_folder`).
#[no_mangle]
pub extern "C" fn ostmac_files_opts(
    chat_id: *const c_char,
    limit: c_int,
    include_folders: c_int,
) -> *mut c_char {
    let lim = if limit <= 0 { 20 } else { limit as usize };
    match cstr_to_string(chat_id) {
        Ok(id) => string_to_c(files_json_opts(&id, lim, include_folders != 0)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// One folder's children by drive+item id. See [`files_children_json`].
#[no_mangle]
pub extern "C" fn ostmac_files_children(
    drive_id: *const c_char,
    item_id: *const c_char,
    limit: c_int,
) -> *mut c_char {
    let lim = if limit <= 0 { 50 } else { limit as usize };
    let drive = match cstr_to_string(drive_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let item = match cstr_to_string(item_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    string_to_c(files_children_json(&drive, &item, lim))
}

/// OneDrive file search, one `$top` window. See [`file_search_json`].
/// Non-positive `limit` means 25.
#[no_mangle]
pub extern "C" fn ostmac_file_search(
    query: *const c_char,
    limit: c_int,
) -> *mut c_char {
    let lim = if limit <= 0 { 25 } else { limit as usize };
    match cstr_to_string(query) {
        Ok(q) => string_to_c(file_search_json(&q, lim)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Directory people search, one `$top` window. See [`people_search_json`].
/// Non-positive `limit` means 25.
#[no_mangle]
pub extern "C" fn ostmac_people_search(
    query: *const c_char,
    limit: c_int,
) -> *mut c_char {
    let lim = if limit <= 0 { 25 } else { limit as usize };
    match cstr_to_string(query) {
        Ok(q) => string_to_c(people_search_json(&q, lim)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Upload a local file to a chat/channel. See [`files_upload_json`].
#[no_mangle]
pub extern "C" fn ostmac_files_upload(
    chat_id: *const c_char,
    path: *const c_char,
) -> *mut c_char {
    let id = match cstr_to_string(chat_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(path) {
        Ok(p) => string_to_c(files_upload_json(&id, &p)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Current upload progress JSON (pure read, no network).
/// See [`upload_progress_json`].
#[no_mangle]
pub extern "C" fn ostmac_files_upload_progress() -> *mut c_char {
    string_to_c(upload_progress_json())
}

/// To Do lists JSON (requires sign-in). See [`reminders_json`].
/// Caller frees with [`ostmac_free`].
#[no_mangle]
pub extern "C" fn ostmac_reminders() -> *mut c_char {
    string_to_c(reminders_json())
}

/// Tasks for one To Do list. See [`reminder_tasks_json`].
#[no_mangle]
pub extern "C" fn ostmac_reminder_tasks(
    list_id: *const c_char,
    limit: c_int,
) -> *mut c_char {
    let lim = if limit <= 0 { 50 } else { limit as usize };
    match cstr_to_string(list_id) {
        Ok(id) => string_to_c(reminder_tasks_json(&id, lim)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Create a view-only sharing link for one driveItem.
/// See [`files_link_json`]. `scope` may be NULL/empty (organization).
#[no_mangle]
pub extern "C" fn ostmac_files_link(
    drive_id: *const c_char,
    item_id: *const c_char,
    scope: *const c_char,
) -> *mut c_char {
    let drive = match cstr_to_string(drive_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let item = match cstr_to_string(item_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match opt_cstr_to_string(scope) {
        Ok(s) => string_to_c(files_link_json(&drive, &item, s.as_deref().unwrap_or(""))),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Download one driveItem's content to `dest`. See [`files_download_json`].
#[no_mangle]
pub extern "C" fn ostmac_files_download(
    drive_id: *const c_char,
    item_id: *const c_char,
    dest: *const c_char,
) -> *mut c_char {
    let drive = match cstr_to_string(drive_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let item = match cstr_to_string(item_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(dest) {
        Ok(d) => string_to_c(files_download_json(&drive, &item, &d)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Version history for one driveItem. See [`file_versions_json`].
#[no_mangle]
pub extern "C" fn ostmac_file_versions(
    drive_id: *const c_char,
    item_id: *const c_char,
) -> *mut c_char {
    let drive = match cstr_to_string(drive_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(item_id) {
        Ok(item) => string_to_c(file_versions_json(&drive, &item)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Restore one version as current. See [`file_version_restore_json`].
#[no_mangle]
pub extern "C" fn ostmac_file_version_restore(
    drive_id: *const c_char,
    item_id: *const c_char,
    version_id: *const c_char,
) -> *mut c_char {
    let drive = match cstr_to_string(drive_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let item = match cstr_to_string(item_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(version_id) {
        Ok(v) => string_to_c(file_version_restore_json(&drive, &item, &v)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Download one old version's content to `dest`. See [`file_version_download_json`].
#[no_mangle]
pub extern "C" fn ostmac_file_version_download(
    drive_id: *const c_char,
    item_id: *const c_char,
    version_id: *const c_char,
    dest: *const c_char,
) -> *mut c_char {
    let drive = match cstr_to_string(drive_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let item = match cstr_to_string(item_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let ver = match cstr_to_string(version_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(dest) {
        Ok(d) => string_to_c(file_version_download_json(&drive, &item, &ver, &d)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Rename one driveItem. See [`files_rename_json`].
#[no_mangle]
pub extern "C" fn ostmac_files_rename(
    drive_id: *const c_char,
    item_id: *const c_char,
    new_name: *const c_char,
) -> *mut c_char {
    let drive = match cstr_to_string(drive_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let item = match cstr_to_string(item_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(new_name) {
        Ok(n) => string_to_c(files_rename_json(&drive, &item, &n)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Move one driveItem to another folder (same drive). See [`files_move_json`].
#[no_mangle]
pub extern "C" fn ostmac_files_move(
    drive_id: *const c_char,
    item_id: *const c_char,
    dest_folder_id: *const c_char,
) -> *mut c_char {
    let drive = match cstr_to_string(drive_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let item = match cstr_to_string(item_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(dest_folder_id) {
        Ok(f) => string_to_c(files_move_json(&drive, &item, &f)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Copy one driveItem to another folder (same drive). `new_name` may be
/// null/empty to keep the source name. See [`files_copy_json`].
#[no_mangle]
pub extern "C" fn ostmac_files_copy(
    drive_id: *const c_char,
    item_id: *const c_char,
    dest_folder_id: *const c_char,
    new_name: *const c_char,
) -> *mut c_char {
    let drive = match cstr_to_string(drive_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let item = match cstr_to_string(item_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let folder = match cstr_to_string(dest_folder_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match opt_cstr_to_string(new_name) {
        Ok(n) => string_to_c(files_copy_json(&drive, &item, &folder, n.as_deref())),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Delete one driveItem. See [`files_delete_json`].
#[no_mangle]
pub extern "C" fn ostmac_files_delete(
    drive_id: *const c_char,
    item_id: *const c_char,
) -> *mut c_char {
    let drive = match cstr_to_string(drive_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(item_id) {
        Ok(i) => string_to_c(files_delete_json(&drive, &i)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Create one task in a list. See [`reminder_add_json`].
#[no_mangle]
pub extern "C" fn ostmac_reminder_add(
    list_id: *const c_char,
    title: *const c_char,
) -> *mut c_char {
    let id = match cstr_to_string(list_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(title) {
        Ok(t) => string_to_c(reminder_add_json(&id, &t)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Mark one task completed. See [`reminder_done_json`].
#[no_mangle]
pub extern "C" fn ostmac_reminder_done(
    list_id: *const c_char,
    task_id: *const c_char,
) -> *mut c_char {
    let id = match cstr_to_string(list_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match cstr_to_string(task_id) {
        Ok(t) => string_to_c(reminder_done_json(&id, &t)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Upcoming meetings JSON (requires sign-in). Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_meetings(limit: c_int) -> *mut c_char {
    let lim = if limit <= 0 { 20 } else { limit as usize };
    string_to_c(meetings_json(lim))
}

/// Classify a pasted join string (pure, no network). Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_meeting_join_parse(raw: *const c_char) -> *mut c_char {
    match cstr_to_string(raw) {
        Ok(s) => string_to_c(meeting_join_parse_json(&s)),
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

/// Blocking poll: waits up to `timeout_ms` for events. Same envelope
/// as [`trouter_poll_json`]. Call off the main thread. Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_trouter_poll_wait(timeout_ms: u64) -> *mut c_char {
    string_to_c(trouter_poll_wait_json(timeout_ms))
}

/// Drain queued Trouter events as typed realtime messages.
/// See [`trouter_poll_typed_json`]. Caller frees with [`ostmac_free`].
#[no_mangle]
pub extern "C" fn ostmac_trouter_poll_typed() -> *mut c_char {
    string_to_c(trouter_poll_typed_json())
}

/// Blocking typed poll: waits up to `timeout_ms` for events. Same
/// envelope as [`trouter_poll_typed_json`]. Call off the main thread.
/// Caller frees with [`ostmac_free`].
#[no_mangle]
pub extern "C" fn ostmac_trouter_poll_typed_wait(timeout_ms: u64) -> *mut c_char {
    string_to_c(trouter_poll_typed_wait_json(timeout_ms))
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

/// OneNote notebooks JSON (requires sign-in). `group_id` null/empty reads
/// the user's own; otherwise the M365 group (team) notebooks. See
/// [`notes_json`]. Caller frees with [`ostmac_free`].
#[no_mangle]
pub extern "C" fn ostmac_notes(group_id: *const c_char) -> *mut c_char {
    match opt_cstr_to_string(group_id) {
        Ok(g) => string_to_c(notes_json(g.as_deref())),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// One notebook's sections (each with pages) as JSON.
/// See [`note_sections_json`]. Caller frees with [`ostmac_free`].
#[no_mangle]
pub extern "C" fn ostmac_note_sections(
    notebook_id: *const c_char,
    group_id: *const c_char,
) -> *mut c_char {
    let nb = match cstr_to_string(notebook_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match opt_cstr_to_string(group_id) {
        Ok(g) => string_to_c(note_sections_json(&nb, g.as_deref())),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// One page's HTML content as JSON. See [`note_page_json`].
/// Caller frees with [`ostmac_free`].
#[no_mangle]
pub extern "C" fn ostmac_note_page(
    page_id: *const c_char,
    group_id: *const c_char,
) -> *mut c_char {
    let id = match cstr_to_string(page_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match opt_cstr_to_string(group_id) {
        Ok(g) => string_to_c(note_page_json(&id, g.as_deref())),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Append one plain-text paragraph to a page: `{ok:true, id}`.
/// See [`note_append_json`]. Caller frees with [`ostmac_free`].
#[no_mangle]
pub extern "C" fn ostmac_note_append(
    page_id: *const c_char,
    text: *const c_char,
    group_id: *const c_char,
) -> *mut c_char {
    let id = match cstr_to_string(page_id) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    let tx = match cstr_to_string(text) {
        Ok(s) => s,
        Err(e) => return string_to_c(err_json("arg", e)),
    };
    match opt_cstr_to_string(group_id) {
        Ok(g) => string_to_c(note_append_json(&id, &tx, g.as_deref())),
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

/// Resolve a Teams MRI (`8:orgid:<aad-oid>`) to a Graph user.
/// See [`resolve_mri_json`]. Caller frees with [`ostmac_free`].
#[no_mangle]
pub extern "C" fn ostmac_resolve_mri(mri: *const c_char) -> *mut c_char {
    match cstr_to_string(mri) {
        Ok(m) => string_to_c(resolve_mri_json(&m)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Place the echo-bot test call, signaling only. See [`calls::call_echo_json`].
#[no_mangle]
pub extern "C" fn ostmac_call_echo(timeout_secs: c_int) -> *mut c_char {
    string_to_c(calls::call_echo_json(timeout_secs as i32))
}

/// Place an outgoing call with live media attached on acceptance.
/// See [`calls::call_place_live_json`].
#[no_mangle]
pub extern "C" fn ostmac_call_place_live(
    thread_id: *const c_char,
    timeout_secs: c_int,
) -> *mut c_char {
    match cstr_to_string(thread_id) {
        Ok(t) => string_to_c(calls::call_place_live_json(&t, timeout_secs as i32)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Place the echo-bot test call with live media. See [`calls::call_echo_live_json`].
#[no_mangle]
pub extern "C" fn ostmac_call_echo_live(timeout_secs: c_int) -> *mut c_char {
    string_to_c(calls::call_echo_live_json(timeout_secs as i32))
}

/// Accept the ringing incoming call. See [`calls::call_accept_json`].
#[no_mangle]
pub extern "C" fn ostmac_call_accept() -> *mut c_char {
    string_to_c(calls::call_accept_json())
}

/// Accept the ringing incoming call with live media.
/// See [`calls::call_accept_live_json`].
#[no_mangle]
pub extern "C" fn ostmac_call_accept_live() -> *mut c_char {
    string_to_c(calls::call_accept_live_json())
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

/// Free a byte payload from any `*_bytes` poll call. Null-safe; `len`
/// must be the length the poll reported.
#[no_mangle]
pub extern "C" fn ostmac_bytes_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
            ptr, len,
        )));
    }
}

// ---------------------------------------------------------------------------
// Tests (deterministic: no network, no sign-in dependency)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Serializes hub-touching tests: the hub is process-global, so
    /// parallel publish/drain across tests races. Hold the guard for
    /// the whole test body.
    fn hub_test_guard() -> std::sync::MutexGuard<'static, ()> {
        static H: OnceLock<Mutex<()>> = OnceLock::new();
        H.get_or_init(|| Mutex::new(()))
            .lock()
            .unwrap_or_else(|e| e.into_inner())
    }

    #[test]
    fn shared_runtime_reused_across_calls() {
        // Perf guard (no timings): rt() must hand out one shared runtime.
        let a = rt().unwrap() as *const tokio::runtime::Runtime;
        let b = rt().unwrap() as *const tokio::runtime::Runtime;
        assert_eq!(a, b, "rt() must return the process-wide shared runtime");
    }

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
    fn chat_create_one_to_one_empty_user_is_arg_error() {
        for bad in ["", "   "] {
            let v: serde_json::Value =
                serde_json::from_str(&chat_create_one_to_one_json(bad)).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_chat_create_one_to_one_null_is_arg_error() {
        unsafe {
            let p = ostmac_chat_create_one_to_one(std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
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
                    description: None,
                    membership_type: None,
                    web_url: None,
                },
                ost::api::ChannelInfo {
                    id: "19:random@thread.tacv2".to_string(),
                    name: "Random".to_string(),
                    description: None,
                    membership_type: None,
                    web_url: None,
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
        // Detail keys always present; null when Graph omits them.
        assert!(v["channels"][0]["description"].is_null());
        assert!(v["channels"][0]["membership_type"].is_null());
        assert!(v["channels"][0]["web_url"].is_null());
    }

    #[test]
    fn channel_json_detail_shape() {
        let t = ost::api::TeamInfo {
            id: "team-1".to_string(),
            name: "Engineering".to_string(),
            channels: vec![ost::api::ChannelInfo {
                id: "19:general@thread.tacv2".to_string(),
                name: "General".to_string(),
                description: Some("Team-wide announcements".to_string()),
                membership_type: Some("standard".to_string()),
                web_url: Some("https://teams.cloud.microsoft/l/channel/abc".to_string()),
            }],
        };
        let v = team_to_json(&t);
        assert_eq!(v["channels"][0]["description"], "Team-wide announcements");
        assert_eq!(v["channels"][0]["membership_type"], "standard");
        assert_eq!(
            v["channels"][0]["web_url"],
            "https://teams.cloud.microsoft/l/channel/abc"
        );
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
    fn channel_create_rejects_bad_args_without_network() {
        for (team_id, name, desc) in [
            ("", "General 2", None),
            ("   ", "General 2", None),
            ("team/a", "General 2", None),
            ("team-1", "", None),
            ("team-1", "   ", Some("d")),
        ] {
            let v: serde_json::Value =
                serde_json::from_str(&channel_create_json(team_id, name, desc)).unwrap();
            assert_eq!(v["ok"], false, "team {:?} name {:?}", team_id, name);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn team_create_rejects_bad_args_without_network() {
        for (name, desc) in [("", None), ("   ", None), ("   ", Some("d"))] {
            let v: serde_json::Value =
                serde_json::from_str(&team_create_json(name, desc)).unwrap();
            assert_eq!(v["ok"], false, "name {:?}", name);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn team_member_json_shape() {
        let m = ost::api::TeamMemberInfo {
            id: "M1".to_string(),
            display_name: "Doe, Jane".to_string(),
            user_id: Some("oid-1".to_string()),
            email: Some("j@x.example".to_string()),
            roles: vec!["owner".to_string()],
            is_owner: true,
        };
        let v = team_member_to_json(&m);
        assert_eq!(v["id"], "M1");
        assert_eq!(v["display_name"], "Doe, Jane");
        assert_eq!(v["user_id"], "oid-1");
        assert_eq!(v["email"], "j@x.example");
        assert_eq!(v["roles"], serde_json::json!(["owner"]));
        assert_eq!(v["is_owner"], true);
    }

    #[test]
    fn team_member_json_null_optionals() {
        let m = ost::api::TeamMemberInfo {
            id: "M3".to_string(),
            display_name: "M3".to_string(),
            user_id: None,
            email: None,
            roles: vec![],
            is_owner: false,
        };
        let v = team_member_to_json(&m);
        assert!(v["user_id"].is_null());
        assert!(v["email"].is_null());
        assert_eq!(v["is_owner"], false);
    }

    #[test]
    fn team_roster_empty_args_is_error() {
        for bad in ["", "   "] {
            let v: serde_json::Value =
                serde_json::from_str(&team_members_json(bad)).unwrap();
            assert_eq!(v["ok"], false, "team={:?}", bad);
            assert_eq!(v["error"], "arg");
            let v: serde_json::Value =
                serde_json::from_str(&team_member_add_json(bad, "u", false)).unwrap();
            assert_eq!(v["error"], "arg");
            let v: serde_json::Value =
                serde_json::from_str(&team_member_add_json("t", bad, false)).unwrap();
            assert_eq!(v["error"], "arg");
            let v: serde_json::Value =
                serde_json::from_str(&team_member_remove_json(bad, "m")).unwrap();
            assert_eq!(v["error"], "arg");
            let v: serde_json::Value =
                serde_json::from_str(&team_member_remove_json("t", bad)).unwrap();
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn channel_create_envelope_shape() {
        let c = ost::api::ChannelInfo {
            id: "19:new@thread.tacv2".to_string(),
            name: "New room".to_string(),
            description: None,
            membership_type: None,
            web_url: None,
        };
        let v = channel_to_json(&c);
        assert_eq!(v["id"], "19:new@thread.tacv2");
        assert_eq!(v["name"], "New room");
    }

    #[test]
    fn ffi_team_roster_null_is_arg_error() {
        unsafe {
            let p = ostmac_team_members(std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");

            let team = CString::new("t1").unwrap();
            let p = ostmac_team_member_add(team.as_ptr(), std::ptr::null(), 0);
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["error"], "arg");

            let p = ostmac_team_member_remove(team.as_ptr(), std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn message_json_shape() {
        let m = ost::api::MessageInfo {
            id: "m1".to_string(),
            sender_mri: "8:orgid:sender".to_string(),
            sender: "A Sender".to_string(),
            timestamp: "2026-09-22T12:00:00Z".to_string(),
            content: "hi".to_string(),
            raw: "<p>hi</p>".to_string(),
            reactions: vec![],
            reply_to: None,
        };
        let v = message_to_json(&m);
        assert_eq!(v["id"], "m1");
        assert_eq!(v["sender"], "A Sender");
        assert_eq!(v["timestamp"], "2026-09-22T12:00:00Z");
        assert_eq!(v["content"], "hi");
        assert_eq!(v["raw"], "<p>hi</p>");
        assert_eq!(v["reactions"].as_array().unwrap().len(), 0);
        assert!(v["reply_to"].is_null());
    }

    #[test]
    fn message_json_shape_carries_reply_to() {
        let m = ost::api::MessageInfo {
            id: "m2".to_string(),
            sender_mri: "8:orgid:b".to_string(),
            sender: "B".to_string(),
            timestamp: "t".to_string(),
            content: "On it!".to_string(),
            raw: "<quote guid=\"m1\">hi</quote><p>On it!</p>".to_string(),
            reactions: vec![],
            reply_to: Some("m1".to_string()),
        };
        let v = message_to_json(&m);
        assert_eq!(v["reply_to"], "m1");
        assert_eq!(v["content"], "On it!");
    }

    #[test]
    fn reply_rejects_bad_args_without_network() {
        for (id, parent, sender, ptext, text) in [
            ("", "m1", "A", "hi", "yo"),
            ("   ", "m1", "A", "hi", "yo"),
            ("19:x", "", "A", "hi", "yo"),
            ("19:x", "  ", "A", "hi", "yo"),
            ("19:x", "m1", "A", "hi", ""),
            ("19:x", "m1", "A", "hi", "  "),
        ] {
            let v: serde_json::Value =
                serde_json::from_str(&reply_json(id, parent, sender, ptext, text)).unwrap();
            assert_eq!(
                v["ok"], false,
                "id={:?} parent={:?} text={:?}",
                id, parent, text
            );
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_reply_null_is_arg_error() {
        let id = CString::new("19:x").unwrap();
        let parent = CString::new("m1").unwrap();
        let sender = CString::new("A").unwrap();
        let ptext = CString::new("hi").unwrap();
        let text = CString::new("yo").unwrap();
        // Each position null in turn; every one is an arg error, never a crash.
        let ptrs = [id.as_ptr(), parent.as_ptr(), sender.as_ptr(), ptext.as_ptr(), text.as_ptr()];
        for i in 0..5 {
            let mut a = ptrs;
            a[i] = std::ptr::null();
            unsafe {
                let p = ostmac_reply(a[0], a[1], a[2], a[3], a[4]);
                assert!(!p.is_null());
                let s = CStr::from_ptr(p).to_string_lossy().into_owned();
                ostmac_free(p);
                let v: serde_json::Value = serde_json::from_str(&s).unwrap();
                assert_eq!(v["ok"], false, "null at {}", i);
                assert_eq!(v["error"], "arg");
            }
        }
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
    fn media_cache_lru_evicts_oldest_over_entry_cap() {
        let mut c = MediaCache::new();
        for i in 0..MEDIA_CACHE_MAX_ENTRIES {
            c.put(format!("https://h/{i}"), "e".to_string());
        }
        assert_eq!(c.len(), MEDIA_CACHE_MAX_ENTRIES);
        c.put("https://h/new".to_string(), "e".to_string());
        assert_eq!(c.len(), MEDIA_CACHE_MAX_ENTRIES);
        assert!(!c.contains("https://h/0"));
        assert!(c.contains("https://h/new"));
    }

    #[test]
    fn media_cache_touch_keeps_hot_entry() {
        let mut c = MediaCache::new();
        for i in 0..MEDIA_CACHE_MAX_ENTRIES {
            c.put(format!("https://h/{i}"), "e".to_string());
        }
        assert!(c.get("https://h/0").is_some()); // touch oldest
        c.put("https://h/new".to_string(), "e".to_string());
        assert!(c.contains("https://h/0")); // survived
        assert!(!c.contains("https://h/1")); // evicted instead
    }

    #[test]
    fn media_cache_rejects_single_item_over_byte_cap() {
        let mut c = MediaCache::new();
        c.put(
            "https://h/big".to_string(),
            "x".repeat(MEDIA_CACHE_MAX_BYTES + 1),
        );
        assert_eq!(c.len(), 0);
    }

    #[test]
    fn media_fetch_serves_cached_url_without_network() {
        // .invalid never resolves: a pass proves the hit path (no runtime).
        let url = "https://cache-probe.invalid/s5-hit.png";
        let envelope = media_envelope(&[1, 2, 3], &Some("image/png".to_string()));
        media_cache()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .put(url.to_string(), envelope.clone());
        assert_eq!(media_fetch_json(url), envelope);
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
    fn react_rejects_bad_args_without_network() {
        for (id, mid, emoji) in [
            ("", "m1", "👍"),
            ("19:x", "", "👍"),
            ("19:x", "m1", ""),
            ("19:x", "m1", "🎉"), // unsupported emoji
        ] {
            for (label, out) in [
                ("react", react_json(id, mid, emoji)),
                ("react_remove", react_remove_json(id, mid, emoji)),
            ] {
                let v: serde_json::Value = serde_json::from_str(&out).unwrap();
                assert_eq!(v["ok"], false, "{} id={:?} mid={:?} e={:?}", label, id, mid, emoji);
                assert_eq!(v["error"], "arg");
            }
        }
    }

    #[test]
    fn edit_delete_empty_args_is_error() {
        for (id, mid, text) in [
            ("", "m1", "hi"),
            ("19:x", "", "hi"),
            ("19:x", "  ", "hi"),
            ("19:x", "m1", ""),
            ("19:x", "m1", "  "),
        ] {
            let v: serde_json::Value =
                serde_json::from_str(&edit_json(id, mid, text)).unwrap();
            assert_eq!(v["ok"], false, "id={:?} mid={:?} text={:?}", id, mid, text);
            assert_eq!(v["error"], "arg");
        }
        for (id, mid) in [("", "m1"), ("19:x", ""), ("19:x", "  ")] {
            let v: serde_json::Value =
                serde_json::from_str(&delete_json(id, mid)).unwrap();
            assert_eq!(v["ok"], false, "id={:?} mid={:?}", id, mid);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn mark_read_receipts_empty_args_is_error() {
        for (id, mid) in [("", "m1"), ("   ", "m1"), ("19:x", ""), ("19:x", "  ")] {
            let v: serde_json::Value =
                serde_json::from_str(&mark_read_json(id, mid)).unwrap();
            assert_eq!(v["ok"], false, "id={:?} mid={:?}", id, mid);
            assert_eq!(v["error"], "arg");
        }
        for bad in ["", "   "] {
            let v: serde_json::Value =
                serde_json::from_str(&receipts_json(bad)).unwrap();
            assert_eq!(v["ok"], false, "thread={:?}", bad);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn team_join_bad_args_is_error() {
        for bad in ["", "   ", "team/1", "a?b", "a#b"] {
            let v: serde_json::Value = serde_json::from_str(&team_join_json(bad)).unwrap();
            assert_eq!(v["ok"], false, "id={:?}", bad);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn tab_json_shape() {
        let t = ost::api::TabInfo {
            id: "tab-1".to_string(),
            name: "Dashboard".to_string(),
            app_id: Some("com.example.dashboard".to_string()),
            content_url: Some("https://example.com/app".to_string()),
            website_url: None,
        };
        let v = tab_to_json(&t);
        assert_eq!(v["id"], "tab-1");
        assert_eq!(v["name"], "Dashboard");
        assert_eq!(v["app_id"], "com.example.dashboard");
        assert_eq!(v["content_url"], "https://example.com/app");
        assert!(v["website_url"].is_null());
    }

    #[test]
    fn tabs_empty_args_is_error() {
        for bad in ["", "   "] {
            let v: serde_json::Value = serde_json::from_str(&tabs_json(bad)).unwrap();
            assert_eq!(v["ok"], false, "channel={:?}", bad);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_team_join_null_is_arg_error() {
        unsafe {
            let p = ostmac_team_join(std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_team_create_null_name_is_arg_error() {
        unsafe {
            let p = ostmac_team_create(std::ptr::null(), std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_tabs_null_is_arg_error() {
        unsafe {
            let p = ostmac_tabs(std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn leave_empty_args_is_error() {
        for bad in ["", "   "] {
            let v: serde_json::Value = serde_json::from_str(&leave_json(bad)).unwrap();
            assert_eq!(v["ok"], false, "chat={:?}", bad);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn receipt_json_shape() {
        let r = ost::api::ReadReceipt {
            user: "8:orgid:a".to_string(),
            message_id: "m1".to_string(),
            horizon: "1;2;m1".to_string(),
        };
        let v = receipt_to_json(&r);
        assert_eq!(v["user"], "8:orgid:a");
        assert_eq!(v["message_id"], "m1");
        assert_eq!(v["horizon"], "1;2;m1");
    }

    #[test]
    fn ffi_mark_read_receipts_null_is_arg_error() {
        let id = CString::new("19:x").unwrap();
        let mid = CString::new("m1").unwrap();
        unsafe {
            let p = ostmac_mark_read(id.as_ptr(), std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");

            let p = ostmac_mark_read(std::ptr::null(), mid.as_ptr());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");

            let p = ostmac_receipts(std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");

            let p = ostmac_leave(std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_react_null_is_arg_error() {
        let id = CString::new("19:x").unwrap();
        let mid = CString::new("m1").unwrap();
        unsafe {
            let p = ostmac_react(id.as_ptr(), mid.as_ptr(), std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_edit_delete_null_is_arg_error() {
        let id = CString::new("19:x").unwrap();
        let mid = CString::new("m1").unwrap();
        let tx = CString::new("hi").unwrap();
        unsafe {
            let p = ostmac_edit(id.as_ptr(), std::ptr::null(), tx.as_ptr());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");

            let p = ostmac_delete(id.as_ptr(), std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");

            // Empty text over FFI also rejects before network.
            let empty = CString::new("  ").unwrap();
            let p = ostmac_edit(id.as_ptr(), mid.as_ptr(), empty.as_ptr());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
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
                sender_mri: "8:orgid:sender".to_string(),
                sender: "A Sender".to_string(),
                timestamp: "2026-09-22T12:00:00Z".to_string(),
                content: "hi Bob".to_string(),
                raw: "<p>hi <at>Bob</at></p>".to_string(),
                reactions: vec![ost::api::ReactionCount {
                    emoji: "👍".to_string(),
                    count: 2,
                }],
                reply_to: None,
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
        assert_eq!(v["messages"][0]["reactions"][0]["emoji"], "👍");
        assert_eq!(v["messages"][0]["reactions"][0]["count"], 2);
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
        let _hub = hub_test_guard();
        let _ = ost::event_hub::drain(1024); // isolate from other tests
        let v: serde_json::Value = serde_json::from_str(&trouter_poll_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["events"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn trouter_event_roundtrip() {
        let _hub = hub_test_guard();
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
    fn trouter_poll_backlog_and_wait_zero_timeout() {
        let _hub = hub_test_guard();
        // Single test: hub is global, parallel hub tests would race.
        let _ = ost::event_hub::drain(1024); // isolate from other tests
        for i in 0..300 {
            ost::event_hub::publish(format!("{{\"i\":{i}}}"));
        }
        let v: serde_json::Value = serde_json::from_str(&trouter_poll_json()).unwrap();
        assert_eq!(v["events"].as_array().unwrap().len(), TROUTER_DRAIN_MAX);
        assert_eq!(
            v["backlog"].as_u64().unwrap(),
            300 - TROUTER_DRAIN_MAX as u64
        );
        let _ = ost::event_hub::drain(1024); // don't leak into neighbors

        ost::event_hub::publish(r#"{"kind":"w"}"#.to_string());
        let v: serde_json::Value = serde_json::from_str(&trouter_poll_wait_json(0)).unwrap();
        assert_eq!(v["events"].as_array().unwrap().len(), 1);
        assert_eq!(v["backlog"].as_u64().unwrap(), 0);
    }

    #[test]
    fn typed_poll_wait_zero_timeout_returns_envelope() {
        let _hub = hub_test_guard();
        let _ = ost::event_hub::drain(1024);
        ost::event_hub::publish(
            r#"{"content":"hi","messagetype":"Text","from":"8:x","threadId":"19:t@thread.v2","id":"1"}"#
                .to_string(),
        );
        let v: serde_json::Value =
            serde_json::from_str(&trouter_poll_typed_wait_json(0)).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["messages"].as_array().unwrap().len(), 1);
        assert_eq!(v["messages"][0]["id"], "1");
        // Drained: second wait returns empty.
        let v2: serde_json::Value =
            serde_json::from_str(&trouter_poll_typed_wait_json(0)).unwrap();
        assert_eq!(v2["messages"].as_array().unwrap().len(), 0);
        assert_eq!(v2["resync"], false);
    }

    #[test]
    fn typed_poll_message_and_loss_and_skip() {
        let _hub = hub_test_guard();
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
    fn typed_poll_carries_typing_events() {
        let _hub = hub_test_guard();
        let _ = ost::event_hub::drain(1024);
        ost::event_hub::publish(
            r#"{"name":"notify","args":[{
                "conversationLink":"https://amer.ng.msg.teams.microsoft.com/v1/users/ME/conversations/19:abc@thread.v2/messages/1",
                "from":"8:orgid:aaa",
                "imdisplayname":"Doe, Jane",
                "messagetype":"Control/Typing",
                "originalarrivaltime":"2026-09-22T14:25:45.000Z"}]}"#
                .to_string(),
        );
        let v: serde_json::Value =
            serde_json::from_str(&trouter_poll_typed_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["messages"].as_array().unwrap().len(), 0);
        let typing = v["typing"].as_array().unwrap();
        assert_eq!(typing.len(), 1);
        assert_eq!(typing[0]["chat_id"], "19:abc@thread.v2");
        assert_eq!(typing[0]["sender"], "Doe, Jane");
        assert_eq!(typing[0]["sender_id"], "8:orgid:aaa");
    }

    #[test]
    fn typed_poll_carries_roster_events() {
        let _hub = hub_test_guard();
        let _ = ost::event_hub::drain(1024);
        ost::event_hub::publish(
            r#"{"name":"conversation/rosterUpdate","args":[{
                "threadid":"19:meeting_x@thread.v2",
                "roster":{"participants":[
                    {"mri":"8:orgid:aaa","displayName":"Doe, Jane","isMuted":false},
                    {"mri":"8:orgid:bbb","displayName":"Smith, Bob","serverMuted":true}
                ]},
                "dominantSpeakerInfo":{"mri":"8:orgid:aaa"}}]}"#
                .to_string(),
        );
        let v: serde_json::Value =
            serde_json::from_str(&trouter_poll_typed_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["messages"].as_array().unwrap().len(), 0);
        let roster = v["roster"].as_array().unwrap();
        assert_eq!(roster.len(), 3); // 2 participants + speaker marker
        assert_eq!(roster[0]["meeting_id"], "19:meeting_x@thread.v2");
        assert_eq!(roster[0]["id"], "8:orgid:aaa");
        assert_eq!(roster[0]["muted"], false);
        assert_eq!(roster[1]["muted"], true);
        assert_eq!(roster[2]["id"], "8:orgid:aaa");
        assert_eq!(roster[2]["speaking"], true);
    }

    #[test]
    fn typed_poll_edit_detection() {
        let _hub = hub_test_guard();
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
        let _hub = hub_test_guard();
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
    fn todo_json_shapes() {
        let l = ost::api::TodoListInfo {
            id: "L1".to_string(),
            name: "Tasks".to_string(),
            wellknown: Some("defaultList".to_string()),
        };
        let v = todo_list_to_json(&l);
        assert_eq!(v["id"], "L1");
        assert_eq!(v["name"], "Tasks");
        assert_eq!(v["wellknown"], "defaultList");
        let l2 = ost::api::TodoListInfo {
            id: "L2".to_string(),
            name: "Groceries".to_string(),
            wellknown: None,
        };
        assert!(todo_list_to_json(&l2)["wellknown"].is_null());

        let t = ost::api::TodoTaskInfo {
            id: "T1".to_string(),
            title: "Buy milk".to_string(),
            status: "notStarted".to_string(),
            importance: "high".to_string(),
            due: Some("2026-09-23T12:00:00.0000000".to_string()),
            reminder: None,
            completed: false,
        };
        let v = todo_task_to_json(&t);
        assert_eq!(v["title"], "Buy milk");
        assert_eq!(v["status"], "notStarted");
        assert_eq!(v["importance"], "high");
        assert_eq!(v["due"], "2026-09-23T12:00:00.0000000");
        assert!(v["reminder"].is_null());
        assert_eq!(v["completed"], false);
    }

    #[test]
    fn reminder_tasks_rejects_bad_list_id_without_network() {
        for bad in ["", "   ", "a/b", "a?b", "a#b", "a b"] {
            let v: serde_json::Value =
                serde_json::from_str(&reminder_tasks_json(bad, 10)).unwrap();
            assert_eq!(v["ok"], false, "id {:?}", bad);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn notes_group_normalizes_scope() {
        assert_eq!(notes_group(None).unwrap(), None);
        assert_eq!(notes_group(Some("")).unwrap(), None);
        assert_eq!(notes_group(Some("  ")).unwrap(), None);
        assert_eq!(
            notes_group(Some(" team-1 ")).unwrap(),
            Some("team-1".to_string())
        );
        for bad in ["a/b", "a b", "../me"] {
            assert!(notes_group(Some(bad)).is_err(), "group {:?}", bad);
        }
    }

    #[test]
    fn reminder_add_rejects_bad_args_without_network() {
        for (id, title) in [
            ("", "hi"),
            ("L1", ""),
            ("L1", "   "),
            ("a/b", "hi"),
            ("L1?x", "hi"),
        ] {
            let v: serde_json::Value =
                serde_json::from_str(&reminder_add_json(id, title)).unwrap();
            assert_eq!(v["ok"], false, "id={:?} title={:?}", id, title);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn notes_json_shapes() {
        let n = ost::api::NotebookInfo {
            id: "nb-1".to_string(),
            name: "Work".to_string(),
        };
        let v = notebook_to_json(&n);
        assert_eq!(v["id"], "nb-1");
        assert_eq!(v["name"], "Work");
        let s = ost::api::SectionInfo {
            id: "s-1".to_string(),
            name: "Notes".to_string(),
            pages: vec![
                ost::api::PageInfo {
                    id: "p-1".to_string(),
                    title: "Kickoff".to_string(),
                    updated: Some("2026-09-22T10:00:00Z".to_string()),
                },
                ost::api::PageInfo {
                    id: "p-2".to_string(),
                    title: "Untitled".to_string(),
                    updated: None,
                },
            ],
        };
        let v = note_section_to_json(&s);
        assert_eq!(v["name"], "Notes");
        assert_eq!(v["pages"].as_array().unwrap().len(), 2);
        assert_eq!(v["pages"][0]["title"], "Kickoff");
        assert_eq!(v["pages"][0]["updated"], "2026-09-22T10:00:00Z");
        assert!(v["pages"][1]["updated"].is_null());
    }

    #[test]
    fn notes_rejects_bad_args_without_network() {
        for bad in ["", "   "] {
            let v: serde_json::Value =
                serde_json::from_str(&note_sections_json(bad, None)).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
            let v: serde_json::Value =
                serde_json::from_str(&note_page_json(bad, None)).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
            let v: serde_json::Value =
                serde_json::from_str(&note_append_json(bad, "hi", None)).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
        // Empty append text rejected (valid page id).
        let v: serde_json::Value =
            serde_json::from_str(&note_append_json("p-1", "  ", None)).unwrap();
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"], "arg");
        // Bad group scope rejected on every entry point.
        for s in [
            notes_json(Some("a/b")),
            note_sections_json("nb-1", Some("a b")),
            note_page_json("p-1", Some("../me")),
            note_append_json("p-1", "hi", Some("a/b")),
        ] {
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn reminder_done_rejects_bad_ids_without_network() {
        for (list, task) in [("", "T1"), ("L1", ""), ("L1", "a/b"), ("a b", "T1")] {
            let v: serde_json::Value =
                serde_json::from_str(&reminder_done_json(list, task)).unwrap();
            assert_eq!(v["ok"], false, "list={:?} task={:?}", list, task);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn meeting_to_json_shape() {
        let m = ost::api::MeetingInfo {
            id: "E1".to_string(),
            subject: "Standup".to_string(),
            start: Some("2026-09-24T09:00:00.0000000".to_string()),
            end: None,
            join_url: Some("https://teams.microsoft.com/l/meetup-join/x".to_string()),
            organizer: Some("Doe, Jane".to_string()),
            is_online: true,
        };
        let v = meeting_to_json(&m);
        assert_eq!(v["id"], "E1");
        assert_eq!(v["subject"], "Standup");
        assert_eq!(v["start"], "2026-09-24T09:00:00.0000000");
        assert!(v["end"].is_null());
        assert_eq!(v["join_url"], "https://teams.microsoft.com/l/meetup-join/x");
        assert_eq!(v["organizer"], "Doe, Jane");
        assert_eq!(v["is_online"], true);
    }

    #[test]
    fn join_parse_json_matrix() {
        // Thread-shaped meetup link.
        let v: serde_json::Value = serde_json::from_str(&meeting_join_parse_json(
            "https://teams.microsoft.com/l/meetup-join/19%3Ameeting_abc%40thread.v2/0",
        ))
        .unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["target"]["kind"], "thread");
        assert_eq!(v["target"]["thread_id"], "19:meeting_abc@thread.v2");
        // Bare thread id.
        let v: serde_json::Value =
            serde_json::from_str(&meeting_join_parse_json("19:abc@thread.v2")).unwrap();
        assert_eq!(v["target"]["kind"], "thread");
        // Live meet id.
        let v: serde_json::Value = serde_json::from_str(&meeting_join_parse_json(
            "https://teams.live.com/meet/9347123456789",
        ))
        .unwrap();
        assert_eq!(v["target"]["kind"], "meeting-id");
        assert_eq!(v["target"]["meeting_id"], "9347123456789");
        // Garbage never dials.
        let v: serde_json::Value =
            serde_json::from_str(&meeting_join_parse_json("hello")).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["target"]["kind"], "unknown");
        assert!(v["target"]["thread_id"].is_null());
    }

    #[test]
    fn ffi_meeting_null_is_arg_error() {
        unsafe {
            let p = ostmac_meeting_join_parse(std::ptr::null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_reminder_nulls_are_arg_errors() {
        let id = CString::new("L1").unwrap();
        unsafe {
            let p = ostmac_reminder_tasks(std::ptr::null(), 10);
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["error"], "arg");

            let p = ostmac_reminder_add(id.as_ptr(), std::ptr::null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["error"], "arg");

            let p = ostmac_reminder_done(std::ptr::null(), id.as_ptr());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn opt_cstr_null_decodes_to_none() {
        // Null group scope decodes to None (user's own OneNote) without
        // touching the network; arg validation for ids still applies.
        assert_eq!(opt_cstr_to_string(std::ptr::null()).unwrap(), None);
        let g = CString::new("team-1").unwrap();
        assert_eq!(
            opt_cstr_to_string(g.as_ptr()).unwrap(),
            Some("team-1".to_string())
        );
        // FFI still rejects a bad group before any network.
        let bad = CString::new("a/b").unwrap();
        unsafe {
            let p = ostmac_notes(bad.as_ptr());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_note_ids_null_is_arg_error() {
        unsafe {
            let p = ostmac_note_sections(std::ptr::null(), std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");

            let p = ostmac_note_page(std::ptr::null(), std::ptr::null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["error"], "arg");

            let id = CString::new("p-1").unwrap();
            let p = ostmac_note_append(id.as_ptr(), std::ptr::null(), std::ptr::null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn typed_poll_id_fallback_is_stable() {
        let _hub = hub_test_guard();
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

    #[test]
    fn typed_poll_carries_sender_mri() {
        let _hub = hub_test_guard();
        let _ = ost::event_hub::drain(1024);
        // Display name wins for `sender`; raw `from` MRI lands in sender_id.
        ost::event_hub::publish(
            r#"{"content":"hi","messagetype":"Text","from":"8:orgid:aaa-1",
                "imdisplayname":"Doe, Jane","threadId":"19:t@thread.v2"}"#
                .to_string(),
        );
        // Plain display name in `from` is not an MRI: sender_id omitted.
        ost::event_hub::publish(
            r#"{"content":"yo","messagetype":"Text","from":"Doe, Jane",
                "threadId":"19:t@thread.v2"}"#
                .to_string(),
        );
        let v: serde_json::Value =
            serde_json::from_str(&trouter_poll_typed_json()).unwrap();
        assert_eq!(v["messages"][0]["sender"], "Doe, Jane");
        assert_eq!(v["messages"][0]["sender_id"], "8:orgid:aaa-1");
        assert_eq!(v["messages"][1]["sender"], "Doe, Jane");
        assert!(v["messages"][1].get("sender_id").is_none());
    }

    #[test]
    fn mri_to_oid_matches_upstream_regex() {
        // teams-access MRI_RE: /^8:orgid:([A-Za-z0-9-]+)$/.
        assert_eq!(
            mri_to_oid("8:orgid:12345678-9abc-def0-1234-56789abcdef0"),
            Some("12345678-9abc-def0-1234-56789abcdef0")
        );
        assert_eq!(mri_to_oid("8:orgid:x"), Some("x")); // guest-style, lenient
        for bad in [
            "",
            "8:orgid:",
            "8:orgid:oid with space",
            "8:orgid:oid/slash",
            "8:orgid:oid_underscore",
            "8:skypeids:aaa", // non-orgid forms don't resolve via Graph
            "8:teamsvisitor:aaa",
            "19:abc@thread.v2",
            "user@example.com",
        ] {
            assert_eq!(mri_to_oid(bad), None, "mri {:?}", bad);
        }
    }

    #[test]
    fn resolve_envelope_shape() {
        let v: serde_json::Value =
            serde_json::from_str(&resolve_envelope("gid-1", Some("a@x.example"), "Doe, Jane"))
                .unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["id"], "gid-1");
        assert_eq!(v["email"], "a@x.example");
        assert_eq!(v["display_name"], "Doe, Jane");
        // Guest: mail null (upstream parity).
        let g: serde_json::Value =
            serde_json::from_str(&resolve_envelope("gid-2", None, "Guest")).unwrap();
        assert!(g["email"].is_null());
    }

    #[test]
    fn resolve_mri_rejects_bad_args_without_network() {
        for bad in ["", "   ", "8:skypeids:aaa", "not-an-mri", "19:t@thread.v2"] {
            let v: serde_json::Value =
                serde_json::from_str(&resolve_mri_json(bad)).unwrap();
            assert_eq!(v["ok"], false, "mri {:?}", bad);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn shared_file_json_shape() {
        let f = ost::api::SharedFile {
            id: "item-1".to_string(),
            name: "deck.pdf".to_string(),
            size: 48211,
            mime: Some("application/pdf".to_string()),
            web_url: Some("https://sp/deck".to_string()),
            download_url: Some("https://dl/deck".to_string()),
            drive_id: Some("D1".to_string()),
            created: Some("2026-09-20T10:00:00Z".to_string()),
            modified: None,
            sender: Some("Megan Harper".to_string()),
            is_folder: false,
            attachment_id: Some("550E8400-E29B-41D4-A716-446655440000".to_string()),
            share_url: Some("https://sp/share/ABC".to_string()),
        };
        let v = shared_file_to_json(&f);
        assert_eq!(v["id"], "item-1");
        assert_eq!(v["name"], "deck.pdf");
        assert_eq!(v["size"], 48211);
        assert_eq!(v["mime"], "application/pdf");
        assert_eq!(v["drive_id"], "D1");
        assert_eq!(v["sender"], "Megan Harper");
        assert_eq!(v["is_folder"], false);
        assert_eq!(v["attachment_id"], "550E8400-E29B-41D4-A716-446655440000");
        assert_eq!(v["share_url"], "https://sp/share/ABC");
        assert!(v["modified"].is_null());
    }

    #[test]
    fn shared_folder_json_shape() {
        let f = ost::api::SharedFile {
            id: "dir-1".to_string(),
            name: "Design".to_string(),
            size: 0,
            mime: None,
            web_url: None,
            download_url: None,
            drive_id: Some("D1".to_string()),
            created: None,
            modified: None,
            sender: None,
            is_folder: true,
            share_url: None,
            attachment_id: None,
        };
        let v = shared_file_to_json(&f);
        assert_eq!(v["id"], "dir-1");
        assert_eq!(v["is_folder"], true);
        assert!(v["mime"].is_null());
        assert!(v["download_url"].is_null());
    }

    #[test]
    fn files_rejects_empty_args_without_network() {
        for bad in ["", "   "] {
            let v: serde_json::Value =
                serde_json::from_str(&files_json(bad, 20)).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
            for incl in [false, true] {
                let v: serde_json::Value =
                    serde_json::from_str(&files_json_opts(bad, 20, incl)).unwrap();
                assert_eq!(v["ok"], false, "incl={}", incl);
                assert_eq!(v["error"], "arg");
            }
        }
        for (d, i) in [("", "i"), ("d", ""), ("  ", "i"), ("d", "  ")] {
            let v: serde_json::Value =
                serde_json::from_str(&files_children_json(d, i, 50)).unwrap();
            assert_eq!(v["ok"], false, "d={:?} i={:?}", d, i);
            assert_eq!(v["error"], "arg");
        }
        for (id, path) in [("", "/tmp/a"), ("19:x", ""), ("19:x", "  ")] {
            let v: serde_json::Value =
                serde_json::from_str(&files_upload_json(id, path)).unwrap();
            assert_eq!(v["ok"], false, "id={:?} path={:?}", id, path);
            assert_eq!(v["error"], "arg");
        }
        for (d, i, dst) in [("", "i", "/tmp/x"), ("d", "", "/tmp/x"), ("d", "i", "")] {
            let v: serde_json::Value =
                serde_json::from_str(&files_download_json(d, i, dst)).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
        // Link: empty ids rejected; scope never rejects (normalizes).
        for (d, i) in [("", "i"), ("d", ""), ("  ", "i")] {
            let v: serde_json::Value =
                serde_json::from_str(&files_link_json(d, i, "organization")).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn search_rejects_empty_query_without_network() {
        // om-ja-search: blank queries never reach Graph.
        for bad in ["", "   "] {
            let v: serde_json::Value =
                serde_json::from_str(&search_json(bad, 0, 25)).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn find_search_rejects_empty_query_without_network() {
        // om-jb-filesearch: blank queries never reach Graph.
        for bad in ["", "   "] {
            let v: serde_json::Value =
                serde_json::from_str(&file_search_json(bad, 25)).unwrap();
            assert_eq!(v["ok"], false, "query={:?}", bad);
            assert_eq!(v["error"], "arg");
            let v: serde_json::Value =
                serde_json::from_str(&people_search_json(bad, 25)).unwrap();
            assert_eq!(v["ok"], false, "query={:?}", bad);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn search_hit_json_shape() {
        // om-ja-search: channel-hit projection (chat_id = channel).
        let h = ost::api::SearchHitInfo {
            message_id: "m9".to_string(),
            chat_id: "19:chan@thread.tacv2".to_string(),
            team_id: Some("t1".to_string()),
            channel_id: Some("19:chan@thread.tacv2".to_string()),
            sender: "Tom".to_string(),
            timestamp: "2026-09-22T09:13:05Z".to_string(),
            preview: "...lane...".to_string(),
            subject: None,
        };
        let v = search_hit_to_json(&h);
        assert_eq!(v["message_id"], "m9");
        assert_eq!(v["chat_id"], "19:chan@thread.tacv2");
        assert_eq!(v["team_id"], "t1");
        assert_eq!(v["sender"], "Tom");
        assert!(v["subject"].is_null());
    }

    #[test]
    fn find_search_null_query_is_arg_error() {
        // om-jb-filesearch: null pointers reject (no network).
        unsafe {
            for p in [
                ostmac_file_search(std::ptr::null(), 25),
                ostmac_people_search(std::ptr::null(), 0),
            ] {
                assert!(!p.is_null());
                let s = CStr::from_ptr(p).to_string_lossy().into_owned();
                ostmac_free(p);
                let v: serde_json::Value = serde_json::from_str(&s).unwrap();
                assert_eq!(v["ok"], false);
                assert_eq!(v["error"], "arg");
            }
        }
    }

    #[test]
    fn find_people_row_reuses_roster_projection() {
        // om-jb-filesearch: directory hit -> TeamMember row, roles empty.
        let m = ost::api::TeamMemberInfo {
            id: "u1".to_string(),
            display_name: "Ava Lindqvist".to_string(),
            user_id: Some("u1".to_string()),
            email: Some("ava@x".to_string()),
            roles: Vec::new(),
            is_owner: false,
        };
        let v = team_member_to_json(&m);
        assert_eq!(v["id"], "u1");
        assert_eq!(v["display_name"], "Ava Lindqvist");
        assert_eq!(v["user_id"], "u1");
        assert_eq!(v["email"], "ava@x");
        assert!(v["roles"].as_array().unwrap().is_empty());
        assert_eq!(v["is_owner"], false);
    }

    #[test]
    fn files_manage_rejects_empty_args_without_network() {
        // om-i3-manage: rename/move/copy/delete guards.
        for (d, i, n) in [
            ("", "i", "n"),
            ("d", "", "n"),
            ("d", "i", ""),
            ("d", "i", "  "),
        ] {
            let v: serde_json::Value = serde_json::from_str(&files_rename_json(d, i, n)).unwrap();
            assert_eq!(v["ok"], false, "d={:?} i={:?} n={:?}", d, i, n);
            assert_eq!(v["error"], "arg");
        }
        for (d, i, f) in [("", "i", "f"), ("d", "", "f"), ("d", "i", "")] {
            let v: serde_json::Value = serde_json::from_str(&files_move_json(d, i, f)).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
        for (d, i, f) in [("", "i", "f"), ("d", "", "f"), ("d", "i", "")] {
            let v: serde_json::Value =
                serde_json::from_str(&files_copy_json(d, i, f, None)).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
        for (d, i) in [("", "i"), ("d", ""), ("  ", "i")] {
            let v: serde_json::Value = serde_json::from_str(&files_delete_json(d, i)).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn upload_percent_clamps_and_handles_empty() {
        assert_eq!(upload_percent(0, 0), 0);
        assert_eq!(upload_percent(0, 100), 0);
        assert_eq!(upload_percent(50, 100), 50);
        assert_eq!(upload_percent(100, 100), 100);
        assert_eq!(upload_percent(200, 100), 100);
        assert_eq!(upload_percent(u64::MAX, 1), 100);
    }

    #[test]
    fn upload_progress_store_roundtrips() {
        // Only this test touches the gauge (empty-arg uploads bail before
        // reset), so no cross-test race: set, read, restore idle.
        upload_progress_reset();
        upload_progress_report(25, 100);
        let v: serde_json::Value = serde_json::from_str(&upload_progress_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["uploaded"], 25);
        assert_eq!(v["total"], 100);
        assert_eq!(v["percent"], 25);
        assert_eq!(v["active"], true);
        upload_progress_finish();
        let v: serde_json::Value = serde_json::from_str(&upload_progress_json()).unwrap();
        assert_eq!(v["active"], false);
    }

    #[test]
    fn not_found_matches_graph_404_text() {
        assert!(is_not_found("HTTP 404 for https://graph.microsoft.com/v1.0/users/x: {}"));
        assert!(!is_not_found("HTTP 401 for https://graph.microsoft.com/v1.0/me: denied"));
        assert!(!is_not_found("token expired"));
    }

    #[test]
    fn ffi_resolve_mri_null_is_arg_error() {
        unsafe {
            let p = ostmac_resolve_mri(std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_resolve_mri_bad_mri_roundtrip() {
        let m = CString::new("8:skypeids:aaa").unwrap();
        unsafe {
            let p = ostmac_resolve_mri(m.as_ptr());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn file_version_json_shape() {
        let f = ost::api::FileVersion {
            id: "3.0".to_string(),
            size: 48211,
            modified: Some("2026-09-20T10:00:00Z".to_string()),
            modified_by: Some("Megan Harper".to_string()),
        };
        let v = file_version_to_json(&f);
        assert_eq!(v["id"], "3.0");
        assert_eq!(v["size"], 48211);
        assert_eq!(v["modified"], "2026-09-20T10:00:00Z");
        assert_eq!(v["modified_by"], "Megan Harper");
        let sparse = ost::api::FileVersion {
            id: "1.0".to_string(),
            size: 0,
            modified: None,
            modified_by: None,
        };
        let s = file_version_to_json(&sparse);
        assert_eq!(s["id"], "1.0");
        assert!(s["modified"].is_null());
        assert!(s["modified_by"].is_null());
    }

    #[test]
    fn versions_rejects_empty_args_without_network() {
        for (d, i) in [("", "i"), ("d", ""), ("  ", "i")] {
            let v: serde_json::Value =
                serde_json::from_str(&file_versions_json(d, i)).unwrap();
            assert_eq!(v["ok"], false, "d={:?} i={:?}", d, i);
            assert_eq!(v["error"], "arg");
        }
        for (d, i, ver) in [("", "i", "1.0"), ("d", "", "1.0"), ("d", "i", "  ")] {
            let v: serde_json::Value =
                serde_json::from_str(&file_version_restore_json(d, i, ver)).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
        for (d, i, ver, dst) in [
            ("", "i", "1.0", "/tmp/x"),
            ("d", "", "1.0", "/tmp/x"),
            ("d", "i", "", "/tmp/x"),
            ("d", "i", "1.0", "  "),
        ] {
            let v: serde_json::Value =
                serde_json::from_str(&file_version_download_json(d, i, ver, dst)).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_versions_null_is_arg_error() {
        let d = CString::new("D1").unwrap();
        let it = CString::new("I1").unwrap();
        let ver = CString::new("1.0").unwrap();
        unsafe {
            let p = ostmac_file_versions(d.as_ptr(), std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
        unsafe {
            let p = ostmac_file_version_restore(d.as_ptr(), it.as_ptr(), std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
        unsafe {
            let p = ostmac_file_version_download(
                d.as_ptr(),
                it.as_ptr(),
                ver.as_ptr(),
                std::ptr::null(),
            );
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_files_null_is_arg_error() {
        unsafe {
            let p = ostmac_files(std::ptr::null(), 20);
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
        let id = CString::new("19:x").unwrap();
        unsafe {
            let p = ostmac_files_upload(id.as_ptr(), std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
        let d = CString::new("D1").unwrap();
        let it = CString::new("I1").unwrap();
        unsafe {
            let p = ostmac_files_download(d.as_ptr(), it.as_ptr(), std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
        unsafe {
            // opts + children NULL ids -> arg error, never a crash.
            let p = ostmac_files_opts(std::ptr::null(), 20, 1);
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
            let p = ostmac_files_children(std::ptr::null(), it.as_ptr(), 50);
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
            let p = ostmac_files_children(d.as_ptr(), std::ptr::null(), 50);
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_files_link_null_ids_are_arg_error() {
        let d = CString::new("D1").unwrap();
        let it = CString::new("I1").unwrap();
        unsafe {
            // NULL drive id -> arg error.
            let p = ostmac_files_link(std::ptr::null(), it.as_ptr(), std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
            // NULL item id -> arg error.
            let p = ostmac_files_link(d.as_ptr(), std::ptr::null(), std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_files_manage_null_is_arg_error() {
        // om-i3-manage: null required ptrs rejected; copy's new_name is nullable.
        unsafe {
            let p = ostmac_files_rename(std::ptr::null(), std::ptr::null(), std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
        unsafe {
            let p = ostmac_files_move(std::ptr::null(), std::ptr::null(), std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
        let d = CString::new("D1").unwrap();
        let it = CString::new("I1").unwrap();
        let f = CString::new("F9").unwrap();
        unsafe {
            // Null new_name passes the FFI layer (no "arg"); it fails later
            // at sign-in/network, never as a null-pointer error.
            let p = ostmac_files_copy(d.as_ptr(), it.as_ptr(), f.as_ptr(), std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_ne!(v["error"], "arg");
        }
        unsafe {
            let p = ostmac_files_copy(std::ptr::null(), it.as_ptr(), f.as_ptr(), std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
        unsafe {
            let p = ostmac_files_delete(std::ptr::null(), std::ptr::null());
            assert!(!p.is_null());
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }
}
