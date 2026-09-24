//! API client module for Microsoft Teams

mod calendar;
mod chat;
pub mod client;
mod files;
mod graph;
mod me;
pub mod media;
mod notes;
mod presence;
mod tabs;
mod teams;
mod todo;

use anyhow::Result;

// Re-export data types for TUI integration
pub use chat::{
    ChatInfo, MessageInfo, MessagesPage, ReactionCount, ReadReceipt, REACTION_EMOJI,
};
pub use calendar::{JoinTarget, LobbyEvent, LobbyState, MeetingInfo};
pub use files::{FileVersion, SharedFile};
pub use me::UserInfo;
pub use notes::{NotePage, NotebookInfo, PageInfo, SectionInfo};
pub use presence::PresenceInfo;
pub use tabs::TabInfo;
pub use teams::TeamInfo;
pub use teams::TeamMemberInfo;
pub use todo::{TodoListInfo, TodoTaskInfo};

// Re-export ChannelInfo for use in TUI sidebar (currently consumed
// only through TeamInfo.channels, but kept public for future callers).
#[allow(unused_imports)]
pub use teams::ChannelInfo;

// Re-export data-returning functions for TUI integration
pub use chat::{
    build_reply_html, consumptionhorizon_body, consumptionhorizon_url,
    consumptionhorizon_value, consumptionhorizons_url, delete_message_with_client,
    edit_message_body, edit_message_with_client, emoji_for_reaction_type, leave_chat_with_client,
    leave_member_url, list_chats_data, mark_read_with_client, message_url, own_member_mri,
    parse_consumptionhorizons, reaction_add_body, reaction_add_url, reaction_remove_url,
    reaction_type_for_emoji, read_messages_data, read_messages_page, read_receipts_data,
    receipt_message_id, remove_reaction_with_client, reply_message_with_client, reply_snippet,
    send_message_with_client, send_reaction_with_client, split_reply_quote, REPLY_SNIPPET_MAX,
};
pub use calendar::{
    calendar_view_path, list_upcoming_meetings_data, lobby_next, parse_calendar_view,
    parse_join_url,
};
pub use files::{
    download_file_data, download_file_version_data, list_chat_files_data,
    list_file_versions_data, restore_file_version_data, upload_file_data,
};
pub use media::{fetch_media_data, MediaBytes, MAX_BYTES};
pub use me::whoami_data;
pub use notes::{
    append_note_paragraph_data, list_notebook_sections_data, list_notebooks_data,
    read_note_page_data,
};
pub use presence::get_presence_data;
pub use tabs::list_tabs_data;
pub use teams::{
    add_member_body, add_team_member_data, create_channel_body, create_channel_data,
    create_channel_path, join_team_data, list_team_members_data, list_teams_data,
    member_path, members_path, remove_team_member_data,
};
pub use todo::{
    complete_todo_task_data, create_todo_task_data, list_todo_lists_data,
    list_todo_tasks_data,
};

/// List recent chats (native Teams API)
pub async fn list_chats(limit: usize) -> Result<()> {
    chat::list_chats(limit).await
}

/// Read messages from a chat (native Teams API)
pub async fn read_messages(chat_id: &str, limit: usize) -> Result<()> {
    chat::read_messages(chat_id, limit).await
}

/// Send a message to a chat (native Teams API)
pub async fn send_message(to: &str, message: &str) -> Result<()> {
    chat::send_message(to, message).await
}

/// Add (or with `remove`, remove) an emoji reaction on one message.
pub async fn react(chat_id: &str, message_id: &str, emoji: &str, remove: bool) -> Result<()> {
    chat::react(chat_id, message_id, emoji, remove).await
}

/// Reply to one message in a chat (quote reply, native Teams API)
pub async fn reply_message(chat_id: &str, parent_id: &str, message: &str) -> Result<()> {
    chat::reply_message(chat_id, parent_id, message).await
}

/// Edit one own message (native Teams API, PUT per-message URL)
pub async fn edit_message(chat_id: &str, message_id: &str, text: &str) -> Result<()> {
    chat::edit_message(chat_id, message_id, text).await
}

/// Delete one own message (native Teams API, DELETE per-message URL)
pub async fn delete_message(chat_id: &str, message_id: &str) -> Result<()> {
    chat::delete_message(chat_id, message_id).await
}

/// Leave one chat thread (native Teams API, DELETE own roster membership)
pub async fn leave_chat(chat_id: &str) -> Result<()> {
    chat::leave_chat(chat_id).await
}

/// Get current presence status
pub async fn get_presence() -> Result<()> {
    presence::get_presence().await
}

/// Set presence status
pub async fn set_presence(status: &str) -> Result<()> {
    presence::set_presence(status).await
}

/// Show current user info
pub async fn whoami() -> Result<()> {
    me::whoami().await
}

/// List joined teams and their channels
pub async fn list_teams() -> Result<()> {
    teams::list_teams().await
}

/// List one team's roster (members + owners; `owners_only` filters)
pub async fn list_team_members(team_id: &str, owners_only: bool) -> Result<()> {
    teams::list_team_members(team_id, owners_only).await
}

/// Add one user to a team (`owner` grants the owner role)
pub async fn add_team_member(team_id: &str, user: &str, owner: bool) -> Result<()> {
    teams::add_team_member(team_id, user, owner).await
}

/// Remove one membership from a team
pub async fn remove_team_member(team_id: &str, member_id: &str) -> Result<()> {
    teams::remove_team_member(team_id, member_id).await
}

/// List shared files in a chat or channel
pub async fn list_files(chat_id: &str, limit: usize) -> Result<()> {
    files::list_files(chat_id, limit).await
}

/// List a channel's pinned tabs (read-only)
pub async fn list_tabs(channel_id: &str) -> Result<()> {
    tabs::list_tabs(channel_id).await
}

/// List upcoming meetings (Graph calendarView, next 7 days)
pub async fn list_upcoming_meetings(limit: usize) -> Result<()> {
    calendar::list_upcoming_meetings(limit).await
}

/// Download a shared file by drive+item id
pub async fn download_file(drive_id: &str, item_id: &str, dest: &str) -> Result<()> {
    files::download_file(drive_id, item_id, dest).await
}

/// Upload a local file to a chat or channel
pub async fn upload_file(chat_id: &str, local_path: &str) -> Result<()> {
    files::upload_file(chat_id, local_path).await
}

/// List Microsoft To Do lists
pub async fn list_todo_lists() -> Result<()> {
    todo::list_todo_lists().await
}

/// List tasks in one To Do list
pub async fn list_todo_tasks(list_id: &str, limit: usize) -> Result<()> {
    todo::list_todo_tasks(list_id, limit).await
}

/// Create one task in a To Do list
pub async fn create_todo_task(list_id: &str, title: &str) -> Result<()> {
    todo::create_todo_task(list_id, title).await
}

/// Mark one To Do task completed
pub async fn complete_todo_task(list_id: &str, task_id: &str) -> Result<()> {
    todo::complete_todo_task(list_id, task_id).await
}

/// OneNote notebooks/sections/pages (read; `--append` edits a page)
pub async fn notes(
    group_id: Option<&str>,
    notebook: Option<&str>,
    page: Option<&str>,
    append: Option<&str>,
) -> Result<()> {
    notes::notes(group_id, notebook, page, append).await
}
