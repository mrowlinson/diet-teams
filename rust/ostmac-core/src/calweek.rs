//! Calendar week + schedule bridge (B1 calendar lane, own module).
//!
//! JSON over FFI for the Swift week grid: `calweek_json` reads an explicit
//! `calendarView` window, `calschedule_json` POSTs a new event (optional
//! Teams online meeting), `calcancel_json` DELETEs one event. Validation
//! runs pre-network and reports `{"ok":false,"error":"arg"}`; network and
//! auth failures report their own `error` code with the Graph detail.

use std::os::raw::{c_char, c_int};

use serde_json::json;

use crate::{cstr_to_string, err_json, now_secs, rt, string_to_c};

fn calmeeting_to_json(m: &ost::api::MeetingInfo) -> serde_json::Value {
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

/// Week-window meetings as JSON. `week_start` is unix seconds (<=0 = now);
/// `days` clamps to 1..=14 (default 7), `limit` to 1..=100 (default 50).
/// Requires sign-in; unsigned yields `{ok:false}`.
pub fn calweek_json(week_start: i64, days: i64, limit: i64) -> String {
    let start = if week_start > 0 {
        week_start as u64
    } else {
        now_secs()
    };
    let days = if days <= 0 { 7 } else { (days as u64).min(14) };
    let limit = if limit <= 0 {
        50usize
    } else {
        (limit as usize).min(100)
    };
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let meetings = ost::api::list_week_meetings_data(&client, start, days, limit)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let items: Vec<_> = meetings.iter().map(calmeeting_to_json).collect();
            Ok(
                json!({"ok": true, "week_start": start, "days": days, "meetings": items})
                    .to_string(),
            )
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("calweek", e),
    }
}

/// Schedule one meeting as JSON. `online` (nonzero) requests a Teams link.
/// Bad inputs yield `{ok:false,"error":"arg"}` without touching network.
pub fn calschedule_json(
    subject: &str,
    start: &str,
    end: &str,
    time_zone: &str,
    online: bool,
) -> String {
    if let Err(e) = ost::api::validate_schedule(subject, start, end, time_zone) {
        return err_json("arg", e);
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let m =
                ost::api::schedule_meeting_data(&client, subject, start, end, time_zone, online)
                    .await
                    .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "event": calmeeting_to_json(&m)}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("calschedule", e),
    }
}

/// Cancel one meeting as JSON. Blank ids yield `arg` pre-network.
pub fn calcancel_json(event_id: &str) -> String {
    if event_id.trim().is_empty() {
        return err_json("arg", "empty event_id");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            ost::api::cancel_meeting_data(&client, event_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({"ok": true, "id": event_id}).to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("calcancel", e),
    }
}

/// Week meetings JSON (requires sign-in). Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_cal_week(week_start: i64, days: c_int, limit: c_int) -> *mut c_char {
    string_to_c(calweek_json(week_start, days as i64, limit as i64))
}

/// Schedule one meeting (requires sign-in; needs Calendars.ReadWrite).
/// `online` nonzero requests a Teams link. Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_cal_schedule(
    subject: *const c_char,
    start: *const c_char,
    end: *const c_char,
    time_zone: *const c_char,
    online: c_int,
) -> *mut c_char {
    let args = || -> Result<(String, String, String, String), String> {
        Ok((
            cstr_to_string(subject)?,
            cstr_to_string(start)?,
            cstr_to_string(end)?,
            cstr_to_string(time_zone)?,
        ))
    };
    match args() {
        Ok((subject, start, end, tz)) => {
            string_to_c(calschedule_json(&subject, &start, &end, &tz, online != 0))
        }
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

/// Cancel one meeting (requires sign-in). Caller frees.
#[no_mangle]
pub extern "C" fn ostmac_cal_cancel(event_id: *const c_char) -> *mut c_char {
    match cstr_to_string(event_id) {
        Ok(id) => string_to_c(calcancel_json(&id)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ostmac_free;
    use std::ffi::{CStr, CString};

    fn from_c(p: *mut c_char) -> serde_json::Value {
        unsafe {
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            ostmac_free(p);
            serde_json::from_str(&s).unwrap()
        }
    }

    #[test]
    fn ffi_cal_nulls_are_arg_errors() {
        unsafe {
            let v = from_c(ostmac_cal_cancel(std::ptr::null()));
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");

            let s = CString::new("x").unwrap();
            let v = from_c(ostmac_cal_schedule(
                s.as_ptr(),
                std::ptr::null(),
                s.as_ptr(),
                s.as_ptr(),
                0,
            ));
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn schedule_bad_inputs_bail_pre_network() {
        // No tokens needed: validation precedes any network/auth.
        for (subject, start, end, tz) in [
            ("", "2026-09-29T10:00:00", "2026-09-29T10:30:00", "UTC"),
            ("S", "junk", "2026-09-29T10:30:00", "UTC"),
            ("S", "2026-09-29T10:30:00", "2026-09-29T10:00:00", "UTC"),
            ("S", "2026-09-29T10:00:00", "2026-09-29T10:30:00", ""),
        ] {
            let v: serde_json::Value =
                serde_json::from_str(&calschedule_json(subject, start, end, tz, true)).unwrap();
            assert_eq!(v["ok"], false, "{:?}", (subject, start, end, tz));
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn cancel_blank_id_is_arg_error() {
        for id in ["", "   "] {
            let v: serde_json::Value = serde_json::from_str(&calcancel_json(id)).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn calmeeting_to_json_shape() {
        let m = ost::api::MeetingInfo {
            id: "W1".to_string(),
            subject: "Mon standup".to_string(),
            start: Some("2026-09-28T09:00:00.0000000".to_string()),
            end: Some("2026-09-28T09:15:00.0000000".to_string()),
            join_url: None,
            organizer: None,
            is_online: false,
        };
        let v = calmeeting_to_json(&m);
        assert_eq!(v["id"], "W1");
        assert_eq!(v["subject"], "Mon standup");
        assert_eq!(v["start"], "2026-09-28T09:00:00.0000000");
        assert_eq!(v["end"], "2026-09-28T09:15:00.0000000");
        assert!(v["join_url"].is_null());
        assert_eq!(v["is_online"], false);
    }
}
