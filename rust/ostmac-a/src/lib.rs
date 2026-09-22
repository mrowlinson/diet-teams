//! ostmac-a: minimal ost core for Swift (C ABI).
//!
//! Surface: version, init, device-code start, chat list, trouter events.
//! TUI/audio/video/call-media excluded. Results cross as JSON via callback.
//!
//! Threading: callbacks fire on Tokio worker threads; Swift must copy the
//! JSON synchronously (pointer is freed on return) and hop to main.

#![allow(unused_imports, unused_variables, dead_code)]

mod api;
mod auth;
mod config;
mod core;
mod trouter;

use std::ffi::{c_char, c_void, CString};
use std::sync::OnceLock;

pub use core::{auth_start, err_json, list_chats, ok_json, VERSION};

/// Callback: (request_id, utf8 json, context). `json` valid during the call.
pub type OstmacCb = unsafe extern "C" fn(req_id: i64, json: *const c_char, ctx: *mut c_void);

fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

fn emit(cb: OstmacCb, req_id: i64, ctx: *mut c_void, payload: String) {
    let c = CString::new(payload).unwrap_or_default();
    unsafe { cb(req_id, c.as_ptr(), ctx) };
}

/// Static version string. Never freed.
#[no_mangle]
pub extern "C" fn ostmac_version() -> *const c_char {
    static S: OnceLock<CString> = OnceLock::new();
    S.get_or_init(|| CString::new(VERSION).unwrap()).as_ptr()
}

/// Init core (runtime + logging). Returns 1 on success.
#[no_mangle]
pub extern "C" fn ostmac_init() -> i32 {
    let _ = runtime();
    1
}

/// Start device-code flow. Callback gets Start payload or error envelope.
#[no_mangle]
pub extern "C" fn ostmac_auth_start(req_id: i64, cb: OstmacCb, ctx: *mut c_void) {
    let ctx_addr = ctx as usize;
    runtime().spawn(async move {
        let payload = match core::auth_start().await {
            Ok(v) => core::ok_json(&v),
            Err(e) => core::err_json(&e),
        };
        emit(cb, req_id, ctx_addr as *mut c_void, payload);
    });
}

/// List chats (needs sign-in). Callback gets rows or error envelope.
#[no_mangle]
pub extern "C" fn ostmac_chats(req_id: i64, limit: i32, cb: OstmacCb, ctx: *mut c_void) {
    let limit = limit.max(1) as usize;
    let ctx_addr = ctx as usize;
    runtime().spawn(async move {
        let payload = match core::list_chats(limit).await {
            Ok(v) => core::ok_json(&v),
            Err(e) => core::err_json(&e),
        };
        emit(cb, req_id, ctx_addr as *mut c_void, payload);
    });
}

/// Stream trouter events; one callback per frame + terminal error/close note.
#[no_mangle]
pub extern "C" fn ostmac_trouter_start(req_id: i64, cb: OstmacCb, ctx: *mut c_void) {
    let ctx_addr = ctx as usize;
    runtime().spawn(async move {
        let res = trouter::run_events(|frame| {
            let payload =
                serde_json::json!({ "ok": true, "data": { "event": frame } }).to_string();
            emit(cb, req_id, ctx_addr as *mut c_void, payload);
        })
        .await;
        match res {
            Ok(()) => emit(
                cb,
                req_id,
                ctx_addr as *mut c_void,
                serde_json::json!({ "ok": true, "data": { "closed": true } }).to_string(),
            ),
            Err(e) => emit(cb, req_id, ctx_addr as *mut c_void, core::err_json(&e)),
        }
    });
}
