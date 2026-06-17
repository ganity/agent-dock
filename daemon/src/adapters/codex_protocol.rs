use std::collections::{HashMap, VecDeque};

use serde::Deserialize;
use serde_json::{json, Value};

use crate::session::model::StoredEvent;

pub struct CodexLineResult {
    pub outgoing: Vec<Value>,
    pub event: Option<StoredEvent>,
}

pub struct CodexSessionProtocol {
    cwd: String,
    next_request_id: usize,
    initialize_request_id: Option<String>,
    pending_thread_request_id: Option<String>,
    resume_thread_id: Option<String>,
    thread_id: Option<String>,
    queued_messages: VecDeque<UserMessage>,
    pending_command_requests: HashMap<String, PendingCommand>,
}

#[derive(Clone, Debug)]
pub struct UserMessage {
    pub text: String,
    pub image_paths: Vec<String>,
}

impl CodexSessionProtocol {
    pub fn new(cwd: String) -> Self {
        Self {
            cwd,
            next_request_id: 1,
            initialize_request_id: None,
            pending_thread_request_id: None,
            resume_thread_id: None,
            thread_id: None,
            queued_messages: VecDeque::new(),
            pending_command_requests: HashMap::new(),
        }
    }

    pub fn new_attached(cwd: String, thread_id: String) -> Self {
        Self {
            cwd,
            next_request_id: 1,
            initialize_request_id: None,
            pending_thread_request_id: None,
            resume_thread_id: Some(thread_id),
            thread_id: None,
            queued_messages: VecDeque::new(),
            pending_command_requests: HashMap::new(),
        }
    }

    pub fn bootstrap_requests(&mut self) -> Vec<Value> {
        let request_id = self.next_id("initialize");
        self.initialize_request_id = Some(request_id.clone());
        vec![build_initialize_request(&request_id)]
    }

    pub fn enqueue_user_message(&mut self, message: UserMessage) -> anyhow::Result<Vec<Value>> {
        if let Some(thread_id) = &self.thread_id {
            return Ok(self.next_user_message_requests(thread_id.clone(), message));
        }

        self.queued_messages.push_back(message);
        Ok(Vec::new())
    }

    pub fn handle_server_line(&mut self, line: &str) -> anyhow::Result<CodexLineResult> {
        if let Some(event) = parse_notification_event(line)? {
            return Ok(CodexLineResult {
                outgoing: Vec::new(),
                event: Some(event),
            });
        }

        let Some(response) = parse_response(line)? else {
            return Ok(CodexLineResult {
                outgoing: Vec::new(),
                event: None,
            });
        };

        if self.initialize_request_id.as_deref() == Some(response.id.as_str()) {
            let request_id = if self.resume_thread_id.is_some() {
                self.next_id("thread-resume")
            } else {
                self.next_id("thread-start")
            };
            self.pending_thread_request_id = Some(request_id.clone());
            let request = if let Some(thread_id) = &self.resume_thread_id {
                build_thread_resume_request(&request_id, thread_id, &self.cwd)
            } else {
                build_thread_start_request(&request_id, &self.cwd)
            };
            return Ok(CodexLineResult {
                outgoing: vec![request],
                event: None,
            });
        }

        if self.pending_thread_request_id.as_deref() == Some(response.id.as_str()) {
            let thread_id = response
                .result
                .get("thread")
                .and_then(|thread| thread.get("id"))
                .and_then(Value::as_str)
                .ok_or_else(|| anyhow::anyhow!("thread/start response missing thread.id"))?
                .to_string();
            self.thread_id = Some(thread_id.clone());
            self.pending_thread_request_id = None;

            let mut outgoing = Vec::new();
            while let Some(message) = self.queued_messages.pop_front() {
                outgoing.extend(self.next_user_message_requests(thread_id.clone(), message));
            }

            return Ok(CodexLineResult {
                outgoing,
                event: None,
            });
        }

        if let Some(command) = self.pending_command_requests.remove(response.id.as_str()) {
            return Ok(CodexLineResult {
                outgoing: Vec::new(),
                event: Some(command_response_event(
                    command,
                    &response.result,
                    response.error_message.as_deref(),
                )),
            });
        }

        Ok(CodexLineResult {
            outgoing: Vec::new(),
            event: None,
        })
    }

    fn next_user_message_requests(
        &mut self,
        thread_id: String,
        message: UserMessage,
    ) -> Vec<Value> {
        if !message.image_paths.is_empty() {
            return vec![self.next_turn_start_request(thread_id, message)];
        }

        let Some(command) = parse_slash_command(&message.text) else {
            return vec![self.next_turn_start_request(thread_id, message)];
        };

        let request_id = self.next_id(command.request_id_label());
        self.pending_command_requests
            .insert(request_id.clone(), command.clone());

        vec![build_command_request(&request_id, &thread_id, &command)]
    }

    fn next_turn_start_request(&mut self, thread_id: String, message: UserMessage) -> Value {
        let request_id = self.next_id("turn-start");
        build_turn_start_request(&request_id, &thread_id, &message)
    }

    fn next_id(&mut self, label: &str) -> String {
        let id = format!("agent-dock-{label}-{}", self.next_request_id);
        self.next_request_id += 1;
        id
    }
}

#[derive(Clone, Debug)]
enum PendingCommand {
    Compact,
    GoalGet,
    GoalSet { objective: String },
    GoalClear,
}

impl PendingCommand {
    fn request_id_label(&self) -> &'static str {
        match self {
            Self::Compact => "thread-compact",
            Self::GoalGet => "thread-goal-get",
            Self::GoalSet { .. } => "thread-goal-set",
            Self::GoalClear => "thread-goal-clear",
        }
    }
}

fn parse_slash_command(text: &str) -> Option<PendingCommand> {
    let trimmed = text.trim();
    if trimmed == "/compact" {
        return Some(PendingCommand::Compact);
    }

    if trimmed == "/goal" {
        return Some(PendingCommand::GoalGet);
    }

    let Some(goal_rest) = trimmed.strip_prefix("/goal ") else {
        return None;
    };
    let objective = goal_rest.trim();
    if objective.is_empty() {
        return Some(PendingCommand::GoalGet);
    }
    if objective == "clear" {
        return Some(PendingCommand::GoalClear);
    }

    Some(PendingCommand::GoalSet {
        objective: objective.to_string(),
    })
}

fn build_command_request(request_id: &str, thread_id: &str, command: &PendingCommand) -> Value {
    match command {
        PendingCommand::Compact => build_thread_compact_start_request(request_id, thread_id),
        PendingCommand::GoalGet => build_thread_goal_get_request(request_id, thread_id),
        PendingCommand::GoalSet { objective } => {
            build_thread_goal_set_request(request_id, thread_id, objective)
        }
        PendingCommand::GoalClear => build_thread_goal_clear_request(request_id, thread_id),
    }
}

pub fn build_initialize_request(request_id: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "initialize",
        "params": {
            "clientInfo": {
                "name": "agent-dock",
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

pub fn build_thread_resume_request(request_id: &str, thread_id: &str, cwd: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "thread/resume",
        "params": {
            "threadId": thread_id,
            "cwd": cwd,
            "approvalPolicy": "never",
            "sandbox": "danger-full-access",
            "personality": "pragmatic"
        }
    })
}

pub fn build_thread_compact_start_request(request_id: &str, thread_id: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "thread/compact/start",
        "params": {
            "threadId": thread_id
        }
    })
}

pub fn build_thread_goal_get_request(request_id: &str, thread_id: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "thread/goal/get",
        "params": {
            "threadId": thread_id
        }
    })
}

pub fn build_thread_goal_set_request(request_id: &str, thread_id: &str, objective: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "thread/goal/set",
        "params": {
            "threadId": thread_id,
            "objective": objective
        }
    })
}

pub fn build_thread_goal_clear_request(request_id: &str, thread_id: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "thread/goal/clear",
        "params": {
            "threadId": thread_id
        }
    })
}

pub fn build_turn_start_request(request_id: &str, thread_id: &str, message: &UserMessage) -> Value {
    let mut input = vec![json!({
        "type": "text",
        "text": message.text
    })];

    input.extend(message.image_paths.iter().map(|path| {
        json!({
            "type": "localImage",
            "path": path,
            "detail": "auto"
        })
    }));

    json!({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "turn/start",
        "params": {
            "threadId": thread_id,
            "input": input
        }
    })
}

fn command_response_event(
    command: PendingCommand,
    result: &Value,
    error_message: Option<&str>,
) -> StoredEvent {
    let text = if let Some(message) = error_message {
        format!("Command failed: {message}")
    } else {
        match command {
            PendingCommand::Compact => "Compaction started.".to_string(),
            PendingCommand::GoalGet => match result.get("goal") {
                Some(Value::Null) | None => "No active goal.".to_string(),
                Some(goal) => format!("Current goal:\n{}", format_goal(goal)),
            },
            PendingCommand::GoalSet { objective } => {
                let details = result
                    .get("goal")
                    .map(format_goal)
                    .unwrap_or_else(|| format!("Objective: {objective}"));
                format!("Goal set:\n{details}")
            }
            PendingCommand::GoalClear => {
                if result
                    .get("cleared")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
                {
                    "Goal cleared.".to_string()
                } else {
                    "No active goal to clear.".to_string()
                }
            }
        }
    };

    StoredEvent {
        id: 0,
        event_type: "assistant.message".to_string(),
        payload_json: json!({ "text": text }).to_string(),
    }
}

fn format_goal(goal: &Value) -> String {
    let objective = goal
        .get("objective")
        .and_then(Value::as_str)
        .unwrap_or("(no objective)");
    let status = goal
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let tokens_used = goal.get("tokensUsed").and_then(Value::as_i64).unwrap_or(0);
    let time_used_seconds = goal
        .get("timeUsedSeconds")
        .and_then(Value::as_i64)
        .unwrap_or(0);

    let mut lines = vec![
        format!("Objective: {objective}"),
        format!("Status: {status}"),
        format!("Tokens used: {tokens_used}"),
        format!("Time used: {time_used_seconds}s"),
    ];

    if let Some(token_budget) = goal.get("tokenBudget").and_then(Value::as_i64) {
        lines.push(format!("Token budget: {token_budget}"));
    }

    lines.join("\n")
}

#[derive(Deserialize)]
struct RpcNotificationEnvelope {
    method: Option<String>,
    params: Option<Value>,
}

pub fn parse_notification_event(line: &str) -> anyhow::Result<Option<StoredEvent>> {
    let envelope: RpcNotificationEnvelope = serde_json::from_str(line)?;
    let params = envelope.params.unwrap_or_default();

    let event_type = match envelope.method.as_deref() {
        Some("item/agentMessage/delta") => {
            if params.get("phase").and_then(Value::as_str) == Some("analysis") {
                "assistant.thinking.delta"
            } else {
                "assistant.message"
            }
        }
        Some("item/reasoning/textDelta") => "assistant.thinking.delta",
        Some("item/completed") => "tool.call.completed",
        Some("item/started") => "tool.call.started",
        Some("turn/completed") => "session.status.changed",
        Some("thread/status/changed") => "session.status.changed",
        _ => return Ok(None),
    };

    if matches!(
        envelope.method.as_deref(),
        Some("item/started" | "item/completed")
    ) {
        let item_type = params
            .get("item")
            .and_then(|item| item.get("type"))
            .and_then(Value::as_str)
            .unwrap_or_default();

        if matches!(item_type, "userMessage" | "agentMessage") {
            return Ok(None);
        }
    }

    let payload_json = match (envelope.method.as_deref(), params) {
        (Some("item/agentMessage/delta"), params) => {
            json!({ "text": params.get("delta").and_then(Value::as_str).unwrap_or_default() })
                .to_string()
        }
        (Some("item/reasoning/textDelta"), params) => {
            json!({ "text": params.get("delta").and_then(Value::as_str).unwrap_or_default() })
                .to_string()
        }
        (_, params) => params.to_string(),
    };

    Ok(Some(StoredEvent {
        id: 0,
        event_type: event_type.to_string(),
        payload_json,
    }))
}

#[derive(Deserialize)]
struct RpcResponseEnvelope {
    id: Value,
    #[serde(default)]
    result: Value,
    #[serde(default)]
    error: Option<RpcErrorEnvelope>,
}

#[derive(Deserialize)]
struct RpcErrorEnvelope {
    message: Option<String>,
}

struct RpcResponse {
    id: String,
    result: Value,
    error_message: Option<String>,
}

fn parse_response(line: &str) -> anyhow::Result<Option<RpcResponse>> {
    let value: Value = serde_json::from_str(line)?;
    if value.get("method").is_some() || value.get("id").is_none() {
        return Ok(None);
    }

    let response: RpcResponseEnvelope = serde_json::from_value(value)?;
    let Some(id) = response.id.as_str() else {
        return Ok(None);
    };

    Ok(Some(RpcResponse {
        id: id.to_string(),
        result: response.result,
        error_message: response.error.and_then(|error| error.message),
    }))
}
