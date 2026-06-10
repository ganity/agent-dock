use serde::Deserialize;
use serde_json::{json, Value};

use crate::session::model::StoredEvent;

pub fn build_initialize_request(request_id: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "initialize",
        "params": {
            "clientInfo": {
                "name": "agent-workspace",
                "version": "0.1.0"
            },
            "capabilities": {
                "notifications": {
                    "suppress": []
                }
            }
        }
    })
}

pub fn build_thread_start_request(request_id: &str, cwd: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "thread/start",
        "params": {
            "cwd": cwd,
            "approvalPolicy": "never",
            "sandbox": "danger-full-access",
            "personality": "pragmatic"
        }
    })
}

pub fn build_turn_start_request(request_id: &str, thread_id: &str, message: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "turn/start",
        "params": {
            "threadId": thread_id,
            "input": [
                {
                    "type": "text",
                    "text": message
                }
            ]
        }
    })
}

#[derive(Deserialize)]
struct RpcNotificationEnvelope {
    method: Option<String>,
    params: Option<Value>,
}

pub fn parse_notification_event(line: &str) -> anyhow::Result<Option<StoredEvent>> {
    let envelope: RpcNotificationEnvelope = serde_json::from_str(line)?;

    let event_type = match envelope.method.as_deref() {
        Some("item/agentMessage/delta") => "assistant.message",
        Some("item/reasoning/textDelta") => "assistant.thinking.delta",
        Some("item/completed") => "tool.call.completed",
        Some("item/started") => "tool.call.started",
        Some("turn/completed") => "session.status.changed",
        Some("thread/status/changed") => "session.status.changed",
        _ => return Ok(None),
    };

    let payload_json = match (envelope.method.as_deref(), envelope.params.unwrap_or_default()) {
        (Some("item/agentMessage/delta"), params) => {
            json!({ "text": params.get("delta").and_then(Value::as_str).unwrap_or_default() }).to_string()
        }
        (Some("item/reasoning/textDelta"), params) => {
            json!({ "text": params.get("delta").and_then(Value::as_str).unwrap_or_default() }).to_string()
        }
        (_, params) => params.to_string(),
    };

    Ok(Some(StoredEvent {
        id: 0,
        event_type: event_type.to_string(),
        payload_json,
    }))
}
