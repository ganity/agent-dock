use serde::Deserialize;

use crate::{adapters::codex_protocol::parse_notification_event, session::model::StoredEvent};

pub fn parse_codex_rpc_line(line: &str) -> anyhow::Result<Option<StoredEvent>> {
    if let Some(event) = parse_notification_event(line)? {
        return Ok(Some(event));
    }

    let envelope: RpcEnvelope = serde_json::from_str(line)?;

    let event_type = match envelope.method.as_deref() {
        Some("session/message") => "assistant.message",
        Some("session/thinking") => "assistant.thinking.delta",
        Some("session/fileChangeReported") => "file.change.reported",
        Some("tool/callStarted") => "tool.call.started",
        Some("tool/callCompleted") => "tool.call.completed",
        _ => return Ok(None),
    };

    Ok(Some(StoredEvent {
        id: 0,
        event_type: event_type.to_string(),
        payload_json: envelope.params.unwrap_or_default().to_string(),
    }))
}

#[derive(Deserialize)]
struct RpcEnvelope {
    method: Option<String>,
    params: Option<serde_json::Value>,
}
