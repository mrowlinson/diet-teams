//! Slim Trouter event channel (no call auto-answer, no media).
//!
//! Reuses ost's session/registrar/websocket modules; each received frame is
//! forwarded to the caller instead of triggering call handling.

pub mod registrar;
pub mod session;
pub mod websocket;

use anyhow::{Context, Result};

use crate::config::Config;

/// Run one Trouter session, invoking `on_frame` for every received frame.
///
/// Returns when the connection closes or errors. No reconnect: the host
/// (Swift) decides retry policy.
pub async fn run_events<F>(mut on_frame: F) -> Result<()>
where
    F: FnMut(String),
{
    let config = Config::load().context("Failed to load config")?;

    let skype_token = config
        .get_skype_token()
        .context("No skype token found. Run login first.")?;
    anyhow::ensure!(
        !skype_token.is_expired(),
        "Skype token expired. Run login to refresh."
    );

    let skype_token_str = &skype_token.token;
    let http = reqwest::Client::new();

    let (session, epid) = session::negotiate(&http, skype_token_str).await?;
    let session_id =
        session::get_session_id(&http, &session, skype_token_str, &epid).await?;
    let mut ws = websocket::TrouterSocket::connect(&session, &session_id, &epid).await?;

    let frame = ws
        .recv_frame()
        .await?
        .context("Connection closed before handshake")?;
    if frame.starts_with("1::") {
        tracing::info!("Trouter handshake ok");
    } else {
        tracing::warn!("Expected 1:: handshake, got: {}", frame);
    }
    on_frame(frame);

    if let Some(ref reg_url) = session.registrar_url {
        if let Err(e) = registrar::register(&http, skype_token_str, reg_url, &session.surl).await
        {
            tracing::warn!("Registrar registration failed: {:#}", e);
        }
    }

    loop {
        match ws.recv_frame().await? {
            Some(text) => on_frame(text),
            None => {
                tracing::info!("Trouter stream ended");
                return Ok(());
            }
        }
    }
}
