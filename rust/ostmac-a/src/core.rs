//! Async core ops behind the C bridge: version, device-code start, chats.

use anyhow::Result;
use oauth2::{
    basic::BasicClient, AuthUrl, ClientId, DeviceAuthorizationUrl, Scope,
    StandardDeviceAuthorizationResponse, TokenUrl,
};
use serde::Serialize;

use crate::api::client::TeamsClient;
use crate::auth::AuthConfig;

/// Crate version surfaced to Swift.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Device-code start payload (JSON to Swift).
#[derive(Debug, Serialize)]
pub struct DeviceCodeStart {
    pub verification_uri: String,
    pub user_code: String,
    pub expires_in_secs: u64,
}

/// Chat row payload (JSON to Swift).
#[derive(Debug, Serialize)]
pub struct ChatRow {
    pub id: String,
    pub name: String,
    pub is_group: bool,
    pub last_message_time: Option<String>,
    pub last_message_sender: Option<String>,
    pub last_message_preview: Option<String>,
}

fn build_client(auth_config: &AuthConfig) -> Result<BasicClient> {
    let auth_url = AuthUrl::new(format!(
        "https://login.microsoftonline.com/{}/oauth2/v2.0/authorize",
        auth_config.tenant
    ))?;
    let token_url = TokenUrl::new(format!(
        "https://login.microsoftonline.com/{}/oauth2/v2.0/token",
        auth_config.tenant
    ))?;
    let device_url = DeviceAuthorizationUrl::new(format!(
        "https://login.microsoftonline.com/{}/oauth2/v2.0/devicecode",
        auth_config.tenant
    ))?;

    Ok(BasicClient::new(
        ClientId::new(auth_config.client_id.to_string()),
        None,
        auth_url,
        Some(token_url),
    )
    .set_device_authorization_url(device_url))
}

/// Request a device code (start of device-code flow). No polling here: the
/// owner completes sign-in in the browser; a later op exchanges/polls.
pub async fn auth_start() -> Result<DeviceCodeStart> {
    let client = build_client(&AuthConfig::default())?;
    let resp: StandardDeviceAuthorizationResponse = client
        .exchange_device_code()?
        .add_scope(Scope::new(
            "https://api.spaces.skype.com/.default".to_string(),
        ))
        .add_scope(Scope::new("offline_access".to_string()))
        .request_async(oauth2::reqwest::async_http_client)
        .await?;
    Ok(DeviceCodeStart {
        verification_uri: resp.verification_uri().as_str().to_string(),
        user_code: resp.user_code().secret().clone(),
        expires_in_secs: resp.expires_in().as_secs(),
    })
}

/// List recent chats as JSON-ready rows. Requires sign-in.
pub async fn list_chats(limit: usize) -> Result<Vec<ChatRow>> {
    let client = TeamsClient::new().await?;
    let chats = crate::api::list_chats_data(&client, limit).await?;
    Ok(chats
        .into_iter()
        .map(|c| ChatRow {
            id: c.id,
            name: c.name,
            is_group: c.is_group,
            last_message_time: c.last_message_time,
            last_message_sender: c.last_message_sender,
            last_message_preview: c.last_message_preview,
        })
        .collect())
}

/// Serialize a payload envelope: {"ok":true,"data":...} / {"ok":false,"error":...}.
pub fn ok_json<T: Serialize>(data: &T) -> String {
    serde_json::json!({ "ok": true, "data": data }).to_string()
}

/// Serialize an error envelope.
pub fn err_json(err: &anyhow::Error) -> String {
    serde_json::json!({ "ok": false, "error": format!("{:#}", err) }).to_string()
}
