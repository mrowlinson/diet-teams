//! Typed realtime feed over raw Trouter events.
//!
//! `trouter_poll_json` yields opaque socket.io payloads. This module turns them
//! into typed chat message/edit events the conversation view can apply:
//! `{chat_id, id, sender, sender_id?, text, time, is_edit, edited_id?,
//! message_type, reactions?, raw}`.
//! `sender_id` is the raw `from` MRI (e.g. `8:orgid:<oid>`) when present —
//! the presence lane resolves it to a Graph user for live chatmate dots.
//!
//! Wire shapes handled (all observed or defensively supported):
//! - socket.io v1 envelope `{"name","args":[...]}` — `args` unwrapped.
//! - `trouter.connected` — handshake marker, skipped (counted).
//! - `trouter.message_loss` with `droppedIndicators[]` — see below.
//! - message resource: `content` + `messagetype`, sender in `imdisplayname`/
//!   `displayname`/`from`, chat id parsed from `conversationlink`
//!   (`.../conversations/<id>/messages/...`) or `threadid`/`conversationid`.
//! - nested envelopes `data` / `resource` / `eventMessages[]` unwrapped.
//! - keys matched case-insensitively (server mixes `composetime`,
//!   `originalarrivaltime`, camelCase variants).
//!
//! Edits: `is_edit` when `messagetype` contains "edit", `skypeeditedid` is
//! present, or the event `type`/`name` mentions an edit. `id` stays the event
//! message id; `edited_id` carries the original message id when known.
//!
//! Reactions (om-reactions): `reactions` / `properties.reactions` arrays
//! (Graph-like `[{reactionType}]`) group into per-emoji counts in picker
//! order. Reaction-only events (no content) yield empty text so the host
//! patches counts onto the known bubble.
//!
//! `message_loss` behavior: the server sends `trouter.message_loss` when it
//! dropped queued indicators (backpressure / reconnect gap / stale etag). It
//! means "push is not a complete log — some events were never delivered".
//! Response: set `resync:true` in the typed envelope. The UI must treat that
//! as "re-fetch the visible conversation(s) via the chat API"; the feed does
//! NOT reconnect on it (the socket is healthy, history is not). Repeated
//! `message_loss` with identical etags is the server steady-state, not an
//! error — still surfaced every time so the UI can decide to re-fetch.
//!
//! Id fallback: messages without any id field get `h:<8hex>` over
//! (chat,sender,text,time) so redeliveries still dedupe. Documented, stable.

use serde::Serialize;
use serde_json::Value;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

/// One chat message (or edit) extracted from a Trouter event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RealtimeMessage {
    pub chat_id: String,
    pub id: String,
    pub sender: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sender_id: Option<String>,
    pub text: String,
    pub time: String,
    pub is_edit: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub edited_id: Option<String>,
    /// Unstripped server HTML (om-richmedia: streaming `<img>` mining).
    pub raw: String,
    /// Grouped reaction counts (om-reactions). Omitted when empty so old
    /// hosts see the pre-reactions envelope; the host patches counts onto
    /// the known bubble and never appends for reaction-only events.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub reactions: Vec<ReactionCount>,
    /// Raw `messagetype` field (e.g. `Text`, `RichText/Html`). Empty when
    /// the event carried none — the rules filter treats that as
    /// unclassifiable (type gate passes) for old-core tolerance.
    pub message_type: String,
}

/// One grouped reaction count: picker emoji + number of reactors.
/// Mirrors `ost::api::ReactionCount` on the typed poll envelope.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ReactionCount {
    pub emoji: String,
    pub count: usize,
}

/// Result of parsing one batch of raw events.
#[derive(Debug, Default)]
pub struct ParsedBatch {
    pub messages: Vec<RealtimeMessage>,
    pub resync: bool,
    pub skipped: usize,
}

/// Parse one batch of raw event payloads (already JSON-decoded `Value`s).
pub fn parse_batch(events: &[Value]) -> ParsedBatch {
    let mut batch = ParsedBatch::default();
    for e in events {
        parse_value(e, &mut batch);
    }
    batch
}

fn parse_value(v: &Value, batch: &mut ParsedBatch) {
    match v {
        Value::Array(items) => {
            for it in items {
                parse_value(it, batch);
            }
        }
        Value::Object(map) => {
            // message_loss anywhere in this object => resync signal.
            if has_loss_marker(map) {
                batch.resync = true;
                batch.skipped += 1;
                return;
            }
            // socket.io v1 envelope {"name","args"}.
            if let Some(args) = map.get("args").and_then(|a| a.as_array()) {
                let name = map
                    .get("name")
                    .and_then(|n| n.as_str())
                    .unwrap_or("")
                    .to_lowercase();
                if name.contains("message_loss") || name.contains("messageloss") {
                    batch.resync = true;
                    batch.skipped += 1;
                    return;
                }
                if name == "trouter.connected" {
                    batch.skipped += 1;
                    return;
                }
                let edit_hint = name.contains("edit");
                for a in args {
                    parse_value_hint(a, edit_hint, batch);
                }
                return;
            }
            // Skype-style nested envelopes.
            if let Some(inner) = map.get("data").filter(|d| d.is_object() || d.is_array()) {
                parse_value(inner, batch);
                return;
            }
            if let Some(inner) = map.get("resource").filter(|d| d.is_object() || d.is_array()) {
                parse_value(inner, batch);
                return;
            }
            if let Some(list) = map.get("eventMessages").and_then(|e| e.as_array()) {
                for it in list {
                    parse_value(it, batch);
                }
                return;
            }
            match message_from_object(map, false) {
                Some(m) => batch.messages.push(m),
                None => batch.skipped += 1,
            }
        }
        _ => batch.skipped += 1,
    }
}

fn parse_value_hint(v: &Value, edit_hint: bool, batch: &mut ParsedBatch) {
    if edit_hint {
        if let Value::Object(map) = v {
            if has_loss_marker(map) {
                batch.resync = true;
                batch.skipped += 1;
                return;
            }
            match message_from_object(map, true) {
                Some(m) => batch.messages.push(m),
                None => parse_value(v, batch),
            }
            return;
        }
    }
    parse_value(v, batch);
}

/// True when the object itself carries a loss marker.
fn has_loss_marker(map: &serde_json::Map<String, Value>) -> bool {
    map.keys().any(|k| {
        let l = k.to_lowercase();
        l == "message_loss" || l == "messageloss" || l == "droppedindicators"
    })
}

/// Case-insensitive object lookup.
fn get_ci<'a>(map: &'a serde_json::Map<String, Value>, key: &str) -> Option<&'a Value> {
    if let Some(v) = map.get(key) {
        return Some(v);
    }
    map.iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(key))
        .map(|(_, v)| v)
}

fn str_ci(map: &serde_json::Map<String, Value>, key: &str) -> Option<String> {
    let v = get_ci(map, key)?;
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

fn first_str(map: &serde_json::Map<String, Value>, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|k| str_ci(map, k))
}

/// Build a typed message from a flat resource object. None = not a message.
/// Reaction-only events (no content, but a `reactions` array) still
/// produce a message with empty text so the host can patch counts.
fn message_from_object(
    map: &serde_json::Map<String, Value>,
    edit_hint: bool,
) -> Option<RealtimeMessage> {
    let reactions = reactions_from(map);
    let content = match first_str(map, &["content", "text"]) {
        Some(c) => c,
        None if !reactions.is_empty() => String::new(),
        None => return None,
    };
    let msgtype = first_str(map, &["messagetype", "messageType"]).unwrap_or_default();
    // Must look like a message: has content plus some message-ish marker.
    let from = first_str(
        map,
        &["imdisplayname", "displayname", "displayName", "from"],
    )
    .unwrap_or_default();
    if from.is_empty() && msgtype.is_empty() && get_ci(map, "conversationlink").is_none() {
        return None;
    }
    let text = strip_html(&content);
    let chat_id = chat_id_from(map);
    let sender = if from.is_empty() { "?".to_string() } else { from };
    // Raw sender MRI for presence resolution. `from` doubles as the
    // display-name fallback above, so re-read it raw: only `8:`-prefixed
    // values (orgid/skypeids/teamsvisitor/...) qualify; display names
    // must never leak into this field.
    let sender_id = str_ci(map, "from").filter(|f| f.starts_with("8:"));
    let time = first_str(
        map,
        &[
            "originalarrivaltime",
            "composetime",
            "createddatetime",
            "arrivaltime",
            "timestamp",
        ],
    )
    .unwrap_or_default();
    let edited_id = first_str(map, &["skypeeditedid"]);
    let type_field = first_str(map, &["type", "resourceType"]).unwrap_or_default();
    let is_edit = edit_hint
        || msgtype.to_lowercase().contains("edit")
        || type_field.to_lowercase().contains("edit")
        || edited_id.is_some();
    let id = first_str(
        map,
        &[
            "id",
            "clientmessageid",
            "messageid",
            "skypemessageid",
            "messageId",
        ],
    )
    .filter(|s| !s.is_empty())
    .unwrap_or_else(|| fallback_id(&chat_id, &sender, &text, &time));
    Some(RealtimeMessage {
        chat_id,
        id,
        sender,
        sender_id,
        text,
        time,
        is_edit,
        edited_id,
        raw: content,
        reactions,
        message_type: msgtype,
    })
}

/// Grouped reaction counts from `reactions` or `properties.reactions`
/// (Graph-like `[{reactionType}]` entries). Unknown/missing types are
/// dropped; canonical picker order. Empty when the event carries none.
fn reactions_from(map: &serde_json::Map<String, Value>) -> Vec<ReactionCount> {
    let list = get_ci(map, "reactions")
        .and_then(|v| v.as_array())
        .or_else(|| {
            get_ci(map, "properties")
                .and_then(|p| p.as_object())
                .and_then(|o| o.get("reactions"))
                .and_then(|v| v.as_array())
        });
    let Some(entries) = list else {
        return Vec::new();
    };
    let mut counts = vec![0usize; ost::api::REACTION_EMOJI.len()];
    for e in entries {
        let t = e
            .as_object()
            .and_then(|o| o.get("reactionType").or_else(|| o.get("reactiontype")))
            .and_then(|v| v.as_str());
        if let Some(t) = t {
            if let Some(i) = ost::api::REACTION_EMOJI
                .iter()
                .position(|(_, known)| known.eq_ignore_ascii_case(t))
            {
                counts[i] += 1;
            }
        }
    }
    ost::api::REACTION_EMOJI
        .iter()
        .zip(counts)
        .filter(|(_, c)| *c > 0)
        .map(|((emoji, _), count)| ReactionCount {
            emoji: emoji.to_string(),
            count,
        })
        .collect()
}

/// Chat id from conversation/resource links or explicit fields.
fn chat_id_from(map: &serde_json::Map<String, Value>) -> String {
    for key in ["conversationlink", "resourcelink", "conversationLink"] {
        if let Some(link) = str_ci(map, key) {
            if let Some(id) = parse_conversation_link(&link) {
                return id;
            }
        }
    }
    first_str(
        map,
        &[
            "threadid",
            "conversationid",
            "chatid",
            "threadId",
            "conversationId",
        ],
    )
    .unwrap_or_default()
}

/// `.../conversations/<id>/messages/...` -> `<id>`.
fn parse_conversation_link(link: &str) -> Option<String> {
    let lower = link.to_lowercase();
    let marker = "/conversations/";
    let start = lower.find(marker)? + marker.len();
    let rest = &link[start..];
    let end = rest.find('/').unwrap_or(rest.len());
    let id = rest[..end].to_string();
    if id.is_empty() {
        None
    } else {
        Some(id)
    }
}

/// Stable content-hash id for messages that carry no id field.
fn fallback_id(chat: &str, sender: &str, text: &str, time: &str) -> String {
    let mut h = DefaultHasher::new();
    chat.hash(&mut h);
    sender.hash(&mut h);
    text.hash(&mut h);
    time.hash(&mut h);
    format!("h:{:08x}", (h.finish() & 0xffff_ffff) as u32)
}

/// Strip HTML tags + decode common entities (mirrors chat API display text).
fn strip_html(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut in_tag = false;
    for ch in html.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(ch),
            _ => {}
        }
    }
    out.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn batch_of(v: Value) -> ParsedBatch {
        parse_batch(std::slice::from_ref(&v))
    }

    #[test]
    fn reactions_group_on_message_events() {
        let batch = batch_of(json!({
            "content": "<p>hi</p>",
            "messagetype": "RichText/Html",
            "imdisplayname": "A",
            "id": "m1",
            "threadid": "19:x",
            "reactions": [
                {"reactionType": "laugh"},
                {"reactionType": "like"},
                {"reactionType": "like"},
                {"reactionType": "party"},
            ],
        }));
        assert_eq!(batch.messages.len(), 1);
        let m = &batch.messages[0];
        assert_eq!(m.text, "hi");
        assert_eq!(
            m.reactions,
            vec![
                ReactionCount {
                    emoji: "👍".to_string(),
                    count: 2
                },
                ReactionCount {
                    emoji: "😂".to_string(),
                    count: 1
                },
            ]
        );
        // Envelope carries counts; empty counts are omitted.
        let env = serde_json::to_value(m).unwrap();
        assert_eq!(env["reactions"][0]["emoji"], "👍");
        let bare = batch_of(json!({
            "content": "<p>hi</p>",
            "messagetype": "RichText/Html",
            "imdisplayname": "A",
            "id": "m2",
            "threadid": "19:x",
        }));
        assert!(bare.messages[0].reactions.is_empty());
        assert!(serde_json::to_value(&bare.messages[0]).unwrap()
            .get("reactions")
            .is_none());
    }

    #[test]
    fn reaction_only_event_yields_empty_text() {
        let batch = batch_of(json!({
            "messagetype": "RichText/Html",
            "imdisplayname": "A",
            "id": "m1",
            "threadid": "19:x",
            "properties": {"reactions": [{"reactionType": "heart"}]},
        }));
        assert_eq!(batch.messages.len(), 1);
        let m = &batch.messages[0];
        assert_eq!(m.text, "");
        assert_eq!(
            m.reactions,
            vec![ReactionCount {
                emoji: "❤️".to_string(),
                count: 1
            }]
        );
        // No content and no reactions is still not a message.
        let skipped = batch_of(json!({
            "messagetype": "RichText/Html",
            "imdisplayname": "A",
            "id": "m9",
            "threadid": "19:x",
        }));
        assert!(skipped.messages.is_empty());
        assert_eq!(skipped.skipped, 1);
    }

    #[test]
    fn message_type_carried_through() {
        let v = json!({
            "content": "hi",
            "messagetype": "RichText/Html",
            "from": "8:orgid:abc",
            "conversationlink": "https://x/conversations/19:abc/messages/1",
        });
        let b = parse_batch(&[v]);
        assert_eq!(b.messages.len(), 1);
        assert_eq!(b.messages[0].message_type, "RichText/Html");
    }

    #[test]
    fn message_type_defaults_empty() {
        let v = json!({"content": "hi", "from": "Bob"});
        let b = parse_batch(&[v]);
        assert_eq!(b.messages.len(), 1);
        assert_eq!(b.messages[0].message_type, "");
    }
}
