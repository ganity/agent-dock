use serde::Deserialize;

use crate::session::model::StoredEvent;

#[derive(Deserialize)]
struct ClaudeContentBlock {
    #[serde(rename = "type")]
    kind: String,
    text: Option<String>,
    thinking: Option<String>,
}

#[derive(Deserialize)]
struct ClaudeMessage {
    content: Vec<ClaudeContentBlock>,
}

#[derive(Deserialize)]
struct ClaudeEnvelope {
    #[serde(rename = "type")]
    kind: String,
    event: Option<ClaudeStreamEvent>,
    message: Option<ClaudeMessage>,
}

#[derive(Deserialize)]
struct ClaudeStreamEvent {
    #[serde(rename = "type")]
    kind: String,
    delta: Option<ClaudeStreamDelta>,
}

#[derive(Deserialize)]
struct ClaudeStreamDelta {
    #[serde(rename = "type")]
    kind: String,
    text: Option<String>,
    thinking: Option<String>,
}

pub fn parse_claude_stream_line(line: &str) -> anyhow::Result<Option<StoredEvent>> {
    let envelope: ClaudeEnvelope = serde_json::from_str(line)?;

    if envelope.kind == "stream_event" {
        return Ok(envelope.event.and_then(stream_event_to_stored_event));
    }

    if envelope.kind != "assistant" {
        return Ok(None);
    }

    let block = match envelope
        .message
        .and_then(|message| message.content.into_iter().next())
    {
        Some(value) => value,
        None => return Ok(None),
    };

    let (event_type, payload_json) = match block.kind.as_str() {
        "thinking" => (
            "assistant.thinking.delta",
            serde_json::json!({ "text": block.thinking.unwrap_or_default() }).to_string(),
        ),
        "text" => (
            "assistant.message",
            serde_json::json!({ "text": block.text.unwrap_or_default() }).to_string(),
        ),
        _ => return Ok(None),
    };

    Ok(Some(StoredEvent {
        id: 0,
        event_type: event_type.to_string(),
        payload_json,
    }))
}

fn stream_event_to_stored_event(event: ClaudeStreamEvent) -> Option<StoredEvent> {
    if event.kind != "content_block_delta" {
        return None;
    }

    let delta = event.delta?;
    let (event_type, text) = match delta.kind.as_str() {
        "text_delta" => ("assistant.message", delta.text.unwrap_or_default()),
        "thinking_delta" => (
            "assistant.thinking.delta",
            delta.thinking.unwrap_or_default(),
        ),
        _ => return None,
    };

    Some(StoredEvent {
        id: 0,
        event_type: event_type.to_string(),
        payload_json: serde_json::json!({ "text": text }).to_string(),
    })
}

#[derive(Deserialize)]
struct ClaudeResultEnvelope {
    #[serde(rename = "type")]
    kind: String,
    session_id: Option<String>,
}

pub fn parse_claude_result_session_id(line: &str) -> anyhow::Result<Option<String>> {
    let envelope: ClaudeResultEnvelope = serde_json::from_str(line)?;
    if envelope.kind != "result" {
        return Ok(None);
    }

    Ok(envelope.session_id)
}
