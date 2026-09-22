//! Bridge/parsing tests for ostmac-a (offline-safe unless marked ignore).

use std::ffi::CStr;
use std::sync::mpsc;
use std::time::Duration;

use ostmac_a::{err_json, ok_json, VERSION};

#[test]
fn version_nonempty() {
    assert!(!VERSION.is_empty());
    let c = unsafe { CStr::from_ptr(ostmac_a::ostmac_version()) };
    assert_eq!(c.to_str().unwrap(), VERSION);
}

#[test]
fn init_ok() {
    assert_eq!(ostmac_a::ostmac_init(), 1);
}

#[test]
fn ok_envelope_shape() {
    let v: serde_json::Value =
        serde_json::from_str(&ok_json(&serde_json::json!({"a": 1}))).unwrap();
    assert_eq!(v["ok"], true);
    assert_eq!(v["data"]["a"], 1);
}

#[test]
fn err_envelope_shape() {
    let v: serde_json::Value =
        serde_json::from_str(&err_json(&anyhow::anyhow!("boom"))).unwrap();
    assert_eq!(v["ok"], false);
    assert!(v["error"].as_str().unwrap().contains("boom"));
}

unsafe extern "C" fn probe_cb(_id: i64, json: *const std::ffi::c_char, ctx: *mut std::ffi::c_void) {
    let s = CStr::from_ptr(json).to_string_lossy().into_owned();
    let tx = &*(ctx as *const mpsc::Sender<String>);
    let _ = tx.send(s);
}

fn recv_one() -> (i64, mpsc::Receiver<String>, *mut std::ffi::c_void) {
    let (tx, rx) = mpsc::channel();
    let boxed = Box::new(tx);
    (1, rx, Box::into_raw(boxed) as *mut std::ffi::c_void)
}

/// Chats without sign-in (or offline) must still yield a valid envelope.
#[test]
fn chats_yields_envelope_unauthenticated() {
    ostmac_a::ostmac_init();
    let (id, rx, ctx) = recv_one();
    ostmac_a::ostmac_chats(id, 5, probe_cb, ctx);
    let json = rx.recv_timeout(Duration::from_secs(30)).expect("callback");
    unsafe {
        drop(Box::from_raw(ctx as *mut mpsc::Sender<String>));
    }
    let v: serde_json::Value = serde_json::from_str(&json).expect("valid json");
    assert!(v.get("ok").is_some(), "envelope has ok: {json}");
    if v["ok"] == false {
        assert!(v["error"].is_string(), "error envelope: {json}");
    }
}

/// Trouter without sign-in must yield an error envelope (fast, no network).
#[test]
fn trouter_yields_error_unauthenticated() {
    ostmac_a::ostmac_init();
    let (id, rx, ctx) = recv_one();
    ostmac_a::ostmac_trouter_start(id, probe_cb, ctx);
    let json = rx.recv_timeout(Duration::from_secs(30)).expect("callback");
    unsafe {
        drop(Box::from_raw(ctx as *mut mpsc::Sender<String>));
    }
    let v: serde_json::Value = serde_json::from_str(&json).expect("valid json");
    assert_eq!(v["ok"], false, "expected auth error: {json}");
    assert!(
        v["error"].as_str().unwrap().contains("login"),
        "mentions login: {json}"
    );
}

/// Live device-code start (network). Ignored by default.
#[test]
#[ignore]
fn auth_start_live_shape() {
    ostmac_a::ostmac_init();
    let (id, rx, ctx) = recv_one();
    ostmac_a::ostmac_auth_start(id, probe_cb, ctx);
    let json = rx.recv_timeout(Duration::from_secs(30)).expect("callback");
    unsafe {
        drop(Box::from_raw(ctx as *mut mpsc::Sender<String>));
    }
    let v: serde_json::Value = serde_json::from_str(&json).expect("valid json");
    assert_eq!(v["ok"], true, "device code start failed: {json}");
    assert!(v["data"]["verification_uri"].is_string());
    assert!(v["data"]["user_code"].is_string());
}
