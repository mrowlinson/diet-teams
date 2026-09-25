//! Team schedule week (Shifts) JSON over the FFI (read-only).
//!
//! One FFI call returns the whole week grid: schedule header + shifts
//! + time-off instances + reasons, so Swift renders with a single
//! round-trip. Balances are host-side counts of approved instances per
//! reason (Graph exposes no balances endpoint). No writes.

use std::ffi::c_char;

use serde_json::json;

use super::{cstr_to_string, err_json, rt, string_to_c};

fn shift_to_json(s: &ost::api::ShiftInfo) -> serde_json::Value {
    json!({
        "id": s.id,
        "user_id": s.user_id,
        "display_name": s.display_name,
        "start": s.start,
        "end": s.end,
        "theme": s.theme,
        "notes": s.notes,
        "is_draft": s.is_draft,
    })
}

fn time_off_to_json(t: &ost::api::TimeOffInfo) -> serde_json::Value {
    json!({
        "id": t.id,
        "user_id": t.user_id,
        "reason_id": t.reason_id,
        "start": t.start,
        "end": t.end,
        "is_draft": t.is_draft,
    })
}

fn reason_to_json(r: &ost::api::TimeOffReason) -> serde_json::Value {
    json!({
        "id": r.id,
        "name": r.name,
        "code": r.code,
    })
}

/// One team's schedule week as JSON (read-only). Requires sign-in;
/// unsigned yields `{ok:false}`. Empty `team_id` is rejected before
/// any network. `{ok:true, team_id, schedule:{enabled, time_zone,
/// provision_status}, shifts:[...], times_off:[...], reasons:[...]}`.
pub fn schedule_week_json(team_id: &str) -> String {
    if team_id.trim().is_empty() {
        return err_json("arg", "empty team_id");
    }
    let run = || -> Result<String, String> {
        let rt = rt()?;
        rt.block_on(async {
            let client = ost::api::client::TeamsClient::new()
                .await
                .map_err(|e| format!("{:#}", e))?;
            let schedule = ost::api::list_schedule_data(&client, team_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let shifts = ost::api::list_shifts_data(&client, team_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let offs = ost::api::list_timesoffs_data(&client, team_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            let reasons = ost::api::list_timeoff_reasons_data(&client, team_id)
                .await
                .map_err(|e| format!("{:#}", e))?;
            Ok(json!({
                "ok": true,
                "team_id": team_id.trim(),
                "schedule": {
                    "enabled": schedule.enabled,
                    "time_zone": schedule.time_zone,
                    "provision_status": schedule.provision_status,
                },
                "shifts": shifts.iter().map(shift_to_json).collect::<Vec<_>>(),
                "times_off": offs.iter().map(time_off_to_json).collect::<Vec<_>>(),
                "reasons": reasons.iter().map(reason_to_json).collect::<Vec<_>>(),
            })
            .to_string())
        })
    };
    match run() {
        Ok(s) => s,
        Err(e) => err_json("schedule_week", e),
    }
}

/// One team's schedule week JSON (read-only). See [`schedule_week_json`].
#[no_mangle]
pub extern "C" fn ostmac_schedule_week(team_id: *const c_char) -> *mut c_char {
    match cstr_to_string(team_id) {
        Ok(t) => string_to_c(schedule_week_json(&t)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_team_id_rejected_pre_network() {
        for bad in ["", "   "] {
            let v: serde_json::Value = serde_json::from_str(&schedule_week_json(bad)).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_null_pointer_yields_arg_error() {
        let p = ostmac_schedule_week(std::ptr::null());
        assert!(!p.is_null());
        let s = unsafe { std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned() };
        unsafe { drop(std::ffi::CString::from_raw(p)) };
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"], "arg");
    }

    #[test]
    fn ffi_empty_team_id_yields_arg_error() {
        let arg = std::ffi::CString::new("").unwrap();
        let p = ostmac_schedule_week(arg.as_ptr());
        let s = unsafe { std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned() };
        unsafe { drop(std::ffi::CString::from_raw(p)) };
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["ok"], false);
    }

    #[test]
    fn row_mappers_emit_snake_case() {
        let s = ost::api::ShiftInfo {
            id: "s1".into(),
            user_id: Some("u1".into()),
            display_name: "Morning".into(),
            start: Some("2026-09-28T09:00:00".into()),
            end: Some("2026-09-28T17:00:00".into()),
            theme: Some("blue".into()),
            notes: None,
            is_draft: false,
        };
        let v = shift_to_json(&s);
        assert_eq!(v["display_name"], "Morning");
        assert_eq!(v["user_id"], "u1");
        assert_eq!(v["is_draft"], false);

        let t = ost::api::TimeOffInfo {
            id: "o1".into(),
            user_id: None,
            reason_id: Some("r1".into()),
            start: None,
            end: None,
            is_draft: true,
        };
        let v = time_off_to_json(&t);
        assert_eq!(v["reason_id"], "r1");
        assert_eq!(v["is_draft"], true);

        let r = ost::api::TimeOffReason {
            id: "r1".into(),
            name: "Vacation".into(),
            code: Some("V".into()),
        };
        let v = reason_to_json(&r);
        assert_eq!(v["name"], "Vacation");
        assert_eq!(v["code"], "V");
    }
}
