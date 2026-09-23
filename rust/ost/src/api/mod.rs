//! API client module for Microsoft Teams

mod chat;
pub mod client;
mod files;
mod graph;
mod me;
pub mod media;
mod notes;
mod presence;
mod teams;
mod todo;

use anyhow::Result;

// Re-export data types for TUI integration
pub use chat::{ChatInfo, MessageInfo, MessagesPage};
pub use files::SharedFile;
pub use me::UserInfo;
pub use notes::{NotePage, NotebookInfo, PageInfo, SectionInfo};
pub use presence::PresenceInfo;
pub use teams::TeamInfo;
pub use todo::{TodoListInfo, TodoTaskInfo};

// Re-export ChannelInfo for use in TUI sidebar (currently consumed
// only through TeamInfo.channels, but kept public for future callers).
#[allow(unused_imports)]
pub use teams::ChannelInfo;

// Re-export data-returning functions for TUI integration
pub use chat::{
    delete_message_with_client, edit_message_body, edit_message_with_client, list_chats_data,
    message_url, read_messages_data, read_messages_page, send_message_with_client,
};
pub use files::{download_file_data, list_chat_files_data, upload_file_data};
pub use media::{fetch_media_data, MediaBytes, MAX_BYTES};
pub use me::whoami_data;
pub use notes::{
    append_note_paragraph_data, list_notebook_sections_data, list_notebooks_data,
    read_note_page_data,
};
pub use presence::get_presence_data;
pub use teams::list_teams_data;
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

/// Edit one own message (native Teams API, PUT per-message URL)
pub async fn edit_message(chat_id: &str, message_id: &str, text: &str) -> Result<()> {
    chat::edit_message(chat_id, message_id, text).await
}

/// Delete one own message (native Teams API, DELETE per-message URL)
pub async fn delete_message(chat_id: &str, message_id: &str) -> Result<()> {
    chat::delete_message(chat_id, message_id).await
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

/// List shared files in a chat or channel
pub async fn list_files(chat_id: &str, limit: usize) -> Result<()> {
    files::list_files(chat_id, limit).await
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
