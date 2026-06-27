use std::collections::{HashMap, VecDeque};

use serde::Deserialize;
use serde_json::{Value, json};

use crate::session::model::StoredEvent;

pub struct CodexLineResult {
    pub outgoing: Vec<Value>,
    pub event: Option<StoredEvent>,
    pub runtime_session_id: Option<String>,
    pub session_status: Option<String>,
    pub runtime_health: Option<String>,
    pub runtime_error_kind: Option<Option<String>>,
    pub runtime_error_message: Option<Option<String>>,
    pub can_accept_user_message: bool,
    pub completed_user_message: bool,
}

pub struct CodexSessionProtocol {
    cwd: String,
    next_request_id: usize,
    initialize_request_id: Option<String>,
    pending_thread_request_id: Option<String>,
    pending_thread_request_is_resume: bool,
    resume_thread_id: Option<String>,
    thread_id: Option<String>,
    current_turn_id: Option<String>,
    in_flight_user_message: bool,
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
            pending_thread_request_is_resume: false,
            resume_thread_id: None,
            thread_id: None,
            current_turn_id: None,
            in_flight_user_message: false,
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
            pending_thread_request_is_resume: false,
            resume_thread_id: Some(thread_id),
            thread_id: None,
            current_turn_id: None,
            in_flight_user_message: false,
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
        if let Some(thread_id) = self.thread_id.clone() {
            let stop_request = if message.image_paths.is_empty() {
                parse_slash_command(&message.text)
                    .filter(|command| matches!(command, PendingCommand::StopTurn))
                    .and_then(|_| self.interrupt_current_turn())
            } else {
                None
            };
            if let Some(request) = stop_request {
                return Ok(vec![request]);
            }
            if self.in_flight_user_message {
                self.queued_messages.push_back(message);
                return Ok(Vec::new());
            }
            return Ok(self.next_user_message_requests(thread_id, message));
        }

        self.queued_messages.push_back(message);
        Ok(Vec::new())
    }

    pub fn interrupt_current_turn(&mut self) -> Option<Value> {
        let thread_id = self.thread_id.clone()?;
        let current_turn_id = self.current_turn_id.clone()?;
        let command = PendingCommand::StopTurn;
        let request_id = self.next_id(command.request_id_label());
        self.pending_command_requests
            .insert(request_id.clone(), command);
        self.in_flight_user_message = true;
        Some(build_turn_interrupt_request(
            &request_id,
            &thread_id,
            &current_turn_id,
        ))
    }

    pub fn is_thread_ready(&self) -> bool {
        self.thread_id.is_some()
    }

    pub fn can_accept_user_message(&self) -> bool {
        self.is_thread_ready() && !self.in_flight_user_message
    }

    pub fn handle_server_line(&mut self, line: &str) -> anyhow::Result<CodexLineResult> {
        let notification = parse_notification_envelope(line)?;
        if let Some(ref envelope) = notification {
            if self.should_ignore_notification(envelope) {
                return Ok(CodexLineResult {
                    outgoing: Vec::new(),
                    event: None,
                    runtime_session_id: None,
                    session_status: None,
                    runtime_health: None,
                    runtime_error_kind: None,
                    runtime_error_message: None,
                    can_accept_user_message: self.can_accept_user_message(),
                    completed_user_message: false,
                });
            }
            self.maybe_bind_current_turn_id(envelope);
        }

        let session_status = parse_notification_event_status(line)?;
        if let Some(event) = parse_notification_event(line)? {
            let completed_user_message = notification.as_ref().is_some_and(|envelope| {
                self.should_complete_user_message(envelope, session_status.as_deref())
            });
            if completed_user_message {
                self.current_turn_id = None;
                self.in_flight_user_message = false;
            }

            let can_accept_user_message = self.can_accept_user_message();
            return Ok(CodexLineResult {
                outgoing: Vec::new(),
                event: Some(event),
                runtime_session_id: None,
                session_status: derive_session_status_from_event_type(session_status),
                runtime_health: derive_runtime_health_from_notification(line)?,
                runtime_error_kind: derive_runtime_error_kind_from_notification(line)?,
                runtime_error_message: derive_runtime_error_message_from_notification(line)?,
                can_accept_user_message,
                completed_user_message,
            });
        }

        let Some(response) = parse_response(line)? else {
            return Ok(CodexLineResult {
                outgoing: Vec::new(),
                event: None,
                runtime_session_id: None,
                session_status: None,
                runtime_health: None,
                runtime_error_kind: None,
                runtime_error_message: None,
                can_accept_user_message: self.can_accept_user_message(),
                completed_user_message: false,
            });
        };

        if self.initialize_request_id.as_deref() == Some(response.id.as_str()) {
            let is_resume = self.resume_thread_id.is_some();
            let request_id = if is_resume {
                self.next_id("thread-resume")
            } else {
                self.next_id("thread-start")
            };
            self.pending_thread_request_id = Some(request_id.clone());
            self.pending_thread_request_is_resume = is_resume;
            let request = if let Some(thread_id) = &self.resume_thread_id {
                build_thread_resume_request(&request_id, thread_id, &self.cwd)
            } else {
                build_thread_start_request(&request_id, &self.cwd)
            };
            return Ok(CodexLineResult {
                outgoing: vec![request],
                event: None,
                runtime_session_id: None,
                session_status: None,
                runtime_health: None,
                runtime_error_kind: None,
                runtime_error_message: None,
                can_accept_user_message: false,
                completed_user_message: false,
            });
        }

        if self.pending_thread_request_id.as_deref() == Some(response.id.as_str()) {
            if self.pending_thread_request_is_resume
                && response
                    .error_message
                    .as_deref()
                    .is_some_and(is_stale_thread_resume_error)
            {
                return Ok(self.fallback_to_fresh_thread_start());
            }

            let maybe_thread_id = response
                .result
                .get("thread")
                .and_then(|thread| thread.get("id"))
                .and_then(Value::as_str);

            if self.pending_thread_request_is_resume && maybe_thread_id.is_none() {
                return Ok(self.fallback_to_fresh_thread_start());
            }

            let thread_id = maybe_thread_id
                .ok_or_else(|| anyhow::anyhow!("thread/start response missing thread.id"))?
                .to_string();
            self.thread_id = Some(thread_id.clone());
            self.pending_thread_request_id = None;
            self.pending_thread_request_is_resume = false;

            let mut outgoing = Vec::new();
            while let Some(message) = self.queued_messages.pop_front() {
                if self.in_flight_user_message {
                    self.queued_messages.push_front(message);
                    break;
                }
                outgoing.extend(self.next_user_message_requests(thread_id.clone(), message));
            }
            let can_accept_user_message = self.can_accept_user_message();

            return Ok(CodexLineResult {
                outgoing,
                event: None,
                runtime_session_id: Some(thread_id),
                session_status: Some("running".to_string()),
                runtime_health: Some("online".to_string()),
                runtime_error_kind: Some(None),
                runtime_error_message: Some(None),
                can_accept_user_message,
                completed_user_message: false,
            });
        }

        if let Some(command) = self.pending_command_requests.remove(response.id.as_str()) {
            let runtime_error_message = response.error_message.as_deref();
            self.current_turn_id = None;
            self.in_flight_user_message = false;
            let mut runtime_session_id = None;
            let mut session_status = None;
            let mut runtime_health = runtime_error_message.map(|_| "recoverable_error".to_string());
            let mut runtime_error_kind = runtime_error_message
                .map(|message| Some(classify_response_error_kind(message).to_string()));
            let mut next_runtime_error_message =
                runtime_error_message.map(|message| Some(message.to_string()));

            if runtime_error_message.is_none() && matches!(command, PendingCommand::NewThread) {
                self.current_turn_id = None;
                self.in_flight_user_message = false;
                self.queued_messages.clear();
                let thread_id = response
                    .result
                    .get("thread")
                    .and_then(|thread| thread.get("id"))
                    .and_then(Value::as_str)
                    .ok_or_else(|| anyhow::anyhow!("thread/start response missing thread.id"))?
                    .to_string();
                self.thread_id = Some(thread_id.clone());
                runtime_session_id = Some(thread_id);
                session_status = Some("running".to_string());
                runtime_health = Some("online".to_string());
                runtime_error_kind = Some(None);
                next_runtime_error_message = Some(None);
            }
            let can_accept_user_message = self.can_accept_user_message();
            return Ok(CodexLineResult {
                outgoing: Vec::new(),
                event: Some(command_response_event(
                    command,
                    &response.result,
                    runtime_error_message,
                )),
                runtime_session_id,
                session_status,
                runtime_health,
                runtime_error_kind,
                runtime_error_message: next_runtime_error_message,
                can_accept_user_message,
                completed_user_message: true,
            });
        }

        Ok(CodexLineResult {
            outgoing: Vec::new(),
            event: None,
            runtime_session_id: None,
            session_status: None,
            runtime_health: None,
            runtime_error_kind: None,
            runtime_error_message: None,
            can_accept_user_message: self.can_accept_user_message(),
            completed_user_message: false,
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

        if matches!(command, PendingCommand::NewThread) {
            self.thread_id = None;
            self.current_turn_id = None;
            self.in_flight_user_message = false;
            self.queued_messages.clear();
        }

        if matches!(command, PendingCommand::StopTurn) {
            return self
                .interrupt_current_turn()
                .into_iter()
                .collect::<Vec<_>>();
        }

        let request_id = self.next_id(command.request_id_label());
        self.pending_command_requests
            .insert(request_id.clone(), command.clone());
        self.in_flight_user_message = true;

        vec![build_command_request(
            &request_id,
            &thread_id,
            &self.cwd,
            &command,
        )]
    }

    fn next_turn_start_request(&mut self, thread_id: String, message: UserMessage) -> Value {
        let request_id = self.next_id("turn-start");
        self.current_turn_id = None;
        self.in_flight_user_message = true;
        build_turn_start_request(&request_id, &thread_id, &message)
    }

    fn next_id(&mut self, label: &str) -> String {
        let id = format!("agent-dock-{label}-{}", self.next_request_id);
        self.next_request_id += 1;
        id
    }

    fn fallback_to_fresh_thread_start(&mut self) -> CodexLineResult {
        let request_id = self.next_id("thread-start");
        self.pending_thread_request_id = Some(request_id.clone());
        self.pending_thread_request_is_resume = false;
        self.resume_thread_id = None;
        CodexLineResult {
            outgoing: vec![build_thread_start_request(&request_id, &self.cwd)],
            event: None,
            runtime_session_id: None,
            session_status: None,
            runtime_health: None,
            runtime_error_kind: None,
            runtime_error_message: None,
            can_accept_user_message: false,
            completed_user_message: false,
        }
    }

    fn should_ignore_notification(&self, envelope: &RpcNotificationEnvelope) -> bool {
        let Some(current_thread_id) = self.thread_id.as_deref() else {
            return false;
        };
        let Some(params) = envelope.params.as_ref() else {
            return false;
        };
        let Some(notification_thread_id) = extract_notification_thread_id(params) else {
            return false;
        };

        notification_thread_id != current_thread_id
    }

    fn maybe_bind_current_turn_id(&mut self, envelope: &RpcNotificationEnvelope) {
        let is_explicit_turn_start = envelope.method.as_deref() == Some("turn/started");
        if !self.in_flight_user_message
            || (self.current_turn_id.is_some() && !is_explicit_turn_start)
        {
            return;
        }
        let Some(params) = envelope.params.as_ref() else {
            return;
        };
        let Some(turn_id) = extract_notification_turn_id(params) else {
            return;
        };

        self.current_turn_id = Some(turn_id.to_string());
    }

    fn should_complete_user_message(
        &self,
        envelope: &RpcNotificationEnvelope,
        session_status: Option<&str>,
    ) -> bool {
        if envelope.method.as_deref() != Some("turn/completed")
            || !self.in_flight_user_message
            || !session_status.is_some_and(is_turn_terminal_status)
        {
            return false;
        }

        let Some(params) = envelope.params.as_ref() else {
            return false;
        };
        let Some(completed_turn_id) = extract_notification_turn_id(params) else {
            return self.current_turn_id.is_none();
        };

        match self.current_turn_id.as_deref() {
            Some(current_turn_id) => current_turn_id == completed_turn_id,
            None => true,
        }
    }
}

#[derive(Clone, Debug)]
enum PendingCommand {
    NewThread,
    StopTurn,
    Compact,
    GoalGet,
    GoalSet { objective: String },
    GoalClear,
}

impl PendingCommand {
    fn request_id_label(&self) -> &'static str {
        match self {
            Self::NewThread => "thread-new",
            Self::StopTurn => "turn-interrupt",
            Self::Compact => "thread-compact",
            Self::GoalGet => "thread-goal-get",
            Self::GoalSet { .. } => "thread-goal-set",
            Self::GoalClear => "thread-goal-clear",
        }
    }
}

fn parse_slash_command(text: &str) -> Option<PendingCommand> {
    let trimmed = text.trim();
    if trimmed == "/new" {
        return Some(PendingCommand::NewThread);
    }

    if trimmed == "/stop" {
        return Some(PendingCommand::StopTurn);
    }

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

fn build_command_request(
    request_id: &str,
    thread_id: &str,
    cwd: &str,
    command: &PendingCommand,
) -> Value {
    match command {
        PendingCommand::NewThread => build_thread_start_request(request_id, cwd),
        PendingCommand::StopTurn => unreachable!("stop is handled before generic command mapping"),
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

pub fn build_turn_interrupt_request(request_id: &str, thread_id: &str, turn_id: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "turn/interrupt",
        "params": {
            "threadId": thread_id,
            "turnId": turn_id
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
            PendingCommand::NewThread => "Started a new agent session.".to_string(),
            PendingCommand::StopTurn => "Stopped the current task.".to_string(),
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
    #[serde(default)]
    params: Option<Value>,
}

fn parse_notification_envelope(line: &str) -> anyhow::Result<Option<RpcNotificationEnvelope>> {
    let value: Value = serde_json::from_str(line)?;
    if value.get("id").is_some() || value.get("method").is_none() {
        return Ok(None);
    }

    Ok(Some(serde_json::from_value(value)?))
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
        Some("error") => "session.error",
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
        (Some("error"), params) => json!({
            "message": params.get("message").and_then(Value::as_str).unwrap_or_default(),
            "threadId": params.get("threadId").and_then(Value::as_str),
            "willRetry": params.get("willRetry").and_then(Value::as_bool).unwrap_or(false)
        })
        .to_string(),
        (_, params) => params.to_string(),
    };

    Ok(Some(StoredEvent {
        id: 0,
        event_type: event_type.to_string(),
        payload_json,
    }))
}

fn parse_notification_event_status(line: &str) -> anyhow::Result<Option<String>> {
    let envelope: RpcNotificationEnvelope = serde_json::from_str(line)?;
    let params = envelope.params.unwrap_or_default();

    let raw_status = match envelope.method.as_deref() {
        Some("thread/status/changed") => params
            .get("status")
            .and_then(|status| status.get("type"))
            .and_then(Value::as_str),
        Some("turn/completed") => extract_notification_turn_status(&params),
        _ => None,
    };

    Ok(raw_status.map(str::to_owned))
}

fn extract_notification_thread_id(params: &Value) -> Option<&str> {
    params.get("threadId").and_then(Value::as_str)
}

fn extract_notification_turn_id(params: &Value) -> Option<&str> {
    params.get("turnId").and_then(Value::as_str).or_else(|| {
        params
            .get("turn")
            .and_then(|turn| turn.get("id"))
            .and_then(Value::as_str)
    })
}

fn extract_notification_turn_status(params: &Value) -> Option<&str> {
    params
        .get("status")
        .and_then(|status| status.get("type"))
        .and_then(Value::as_str)
        .or_else(|| {
            params
                .get("turn")
                .and_then(|turn| turn.get("status"))
                .and_then(Value::as_str)
        })
        .or_else(|| {
            params
                .get("turn")
                .and_then(|turn| turn.get("status"))
                .and_then(|status| status.get("type"))
                .and_then(Value::as_str)
        })
}

fn derive_session_status_from_event_type(raw_status: Option<String>) -> Option<String> {
    match raw_status.as_deref() {
        Some("active") | Some("running") => Some("running".to_string()),
        Some("idle") => Some("idle".to_string()),
        Some("failed") => Some("failed".to_string()),
        Some("completed") => Some("suspended".to_string()),
        _ => None,
    }
}

fn is_turn_terminal_status(raw_status: &str) -> bool {
    matches!(
        raw_status,
        "completed" | "failed" | "cancelled" | "canceled"
    )
}

fn derive_runtime_health_from_notification(line: &str) -> anyhow::Result<Option<String>> {
    let envelope: RpcNotificationEnvelope = serde_json::from_str(line)?;
    let params = envelope.params.unwrap_or_default();

    match envelope.method.as_deref() {
        Some("thread/status/changed")
            if params
                .get("status")
                .and_then(|status| status.get("type"))
                .and_then(Value::as_str)
                == Some("systemError") =>
        {
            Ok(Some("recoverable_error".to_string()))
        }
        Some("error") => Ok(Some("recoverable_error".to_string())),
        _ => Ok(None),
    }
}

fn derive_runtime_error_kind_from_notification(
    line: &str,
) -> anyhow::Result<Option<Option<String>>> {
    let envelope: RpcNotificationEnvelope = serde_json::from_str(line)?;
    let params = envelope.params.unwrap_or_default();

    match envelope.method.as_deref() {
        Some("error") => Ok(Some(Some(
            classify_runtime_error_kind(
                params
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
            )
            .to_string(),
        ))),
        Some("thread/status/changed")
            if params
                .get("status")
                .and_then(|status| status.get("type"))
                .and_then(Value::as_str)
                == Some("systemError") =>
        {
            Ok(Some(Some("provider".to_string())))
        }
        _ => Ok(None),
    }
}

fn derive_runtime_error_message_from_notification(
    line: &str,
) -> anyhow::Result<Option<Option<String>>> {
    let envelope: RpcNotificationEnvelope = serde_json::from_str(line)?;
    let params = envelope.params.unwrap_or_default();

    match envelope.method.as_deref() {
        Some("error") => Ok(Some(
            params
                .get("message")
                .and_then(Value::as_str)
                .map(str::to_owned),
        )),
        Some("thread/status/changed")
            if params
                .get("status")
                .and_then(|status| status.get("type"))
                .and_then(Value::as_str)
                == Some("systemError") =>
        {
            Ok(Some(
                params
                    .get("status")
                    .and_then(|status| status.get("message"))
                    .and_then(Value::as_str)
                    .map(str::to_owned),
            ))
        }
        _ => Ok(None),
    }
}

fn classify_runtime_error_kind(message: &str) -> &'static str {
    classify_response_error_kind(message)
}

fn classify_response_error_kind(message: &str) -> &'static str {
    let normalized = message.trim().to_ascii_lowercase();
    if is_stale_thread_resume_error(message) {
        "stale_thread"
    } else if normalized.contains("429")
        || normalized.contains("401")
        || normalized.contains("403")
        || normalized.contains("502")
        || normalized.contains("503")
        || normalized.contains("504")
        || normalized.contains("bad gateway")
        || normalized.contains("unauthorized")
        || normalized.contains("forbidden")
        || normalized.contains("rate limit")
        || normalized.contains("provider")
        || normalized.contains("compact service")
    {
        "provider"
    } else if normalized.contains("connection")
        || normalized.contains("timeout")
        || normalized.contains("timed out")
        || normalized.contains("transport")
        || normalized.contains("socket")
        || normalized.contains("econn")
        || normalized.contains("network")
    {
        "transport"
    } else {
        "runtime"
    }
}

fn is_stale_thread_resume_error(message: &str) -> bool {
    let normalized = message.trim().to_ascii_lowercase();
    normalized.contains("unknown thread")
        || normalized.contains("thread not found")
        || normalized.contains("no thread found")
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
