use agent_dock_daemon::adapters::codex_protocol::{
    CodexSessionProtocol, UserMessage, build_initialize_request, build_thread_resume_request,
    build_thread_start_request, build_turn_start_request, parse_notification_event,
};

#[test]
fn initialize_request_uses_initialize_method() {
    let request = build_initialize_request("req-1");

    assert_eq!(request["jsonrpc"], "2.0");
    assert_eq!(request["id"], "req-1");
    assert_eq!(request["method"], "initialize");
    assert_eq!(request["params"]["clientInfo"]["name"], "agent-dock");
}

#[test]
fn thread_start_request_uses_thread_start_method_and_cwd() {
    let request = build_thread_start_request("req-2", "/tmp/workspace");

    assert_eq!(request["method"], "thread/start");
    assert_eq!(request["params"]["cwd"], "/tmp/workspace");
}

#[test]
fn thread_resume_request_uses_thread_resume_method_and_thread_id() {
    let request = build_thread_resume_request("req-2", "thread-1", "/tmp/workspace");

    assert_eq!(request["method"], "thread/resume");
    assert_eq!(request["params"]["threadId"], "thread-1");
    assert_eq!(request["params"]["cwd"], "/tmp/workspace");
}

#[test]
fn turn_start_request_uses_text_user_input_shape() {
    let request = build_turn_start_request(
        "req-3",
        "thread-1",
        &UserMessage {
            text: "hello world".into(),
            image_paths: Vec::new(),
        },
    );

    assert_eq!(request["method"], "turn/start");
    assert_eq!(request["params"]["threadId"], "thread-1");
    assert_eq!(request["params"]["input"][0]["type"], "text");
    assert_eq!(request["params"]["input"][0]["text"], "hello world");
}

#[test]
fn turn_start_request_includes_local_image_inputs_after_text() {
    let request = build_turn_start_request(
        "req-3",
        "thread-1",
        &UserMessage {
            text: "explain this screenshot".into(),
            image_paths: vec!["/tmp/agent-dock/image.png".into()],
        },
    );

    assert_eq!(request["params"]["input"][0]["type"], "text");
    assert_eq!(request["params"]["input"][1]["type"], "localImage");
    assert_eq!(
        request["params"]["input"][1]["path"],
        "/tmp/agent-dock/image.png"
    );
    assert_eq!(request["params"]["input"][1]["detail"], "auto");
}

#[test]
fn parse_notification_event_maps_real_codex_methods() {
    let reasoning = r#"{"method":"item/reasoning/textDelta","params":{"delta":"plan","itemId":"i1","threadId":"t1","turnId":"u1","contentIndex":0}}"#;
    let assistant = r#"{"method":"item/agentMessage/delta","params":{"delta":"done","itemId":"i2","threadId":"t1","turnId":"u1"}}"#;

    let reasoning_event = parse_notification_event(reasoning).unwrap().unwrap();
    let assistant_event = parse_notification_event(assistant).unwrap().unwrap();

    assert_eq!(reasoning_event.event_type, "assistant.thinking.delta");
    assert_eq!(assistant_event.event_type, "assistant.message");
}

#[test]
fn parse_notification_event_maps_analysis_agent_delta_to_thinking() {
    let reasoning = r#"{"method":"item/agentMessage/delta","params":{"delta":"inspect context","itemId":"i1","threadId":"t1","turnId":"u1","phase":"analysis"}}"#;

    let event = parse_notification_event(reasoning).unwrap().unwrap();

    assert_eq!(event.event_type, "assistant.thinking.delta");
    assert!(event.payload_json.contains("inspect context"));
}

#[test]
fn parse_notification_event_ignores_user_and_agent_message_item_lifecycle() {
    let user_started = r#"{"method":"item/started","params":{"item":{"id":"u1","type":"userMessage"},"threadId":"t1","turnId":"x","startedAtMs":1}}"#;
    let agent_completed = r#"{"method":"item/completed","params":{"item":{"id":"a1","type":"agentMessage"},"threadId":"t1","turnId":"x","completedAtMs":2}}"#;

    assert!(parse_notification_event(user_started).unwrap().is_none());
    assert!(parse_notification_event(agent_completed).unwrap().is_none());
}

#[test]
fn parse_notification_event_keeps_real_tool_lifecycle() {
    let tool_started = r#"{"method":"item/started","params":{"item":{"id":"tool-1","type":"local_shell_call"},"threadId":"t1","turnId":"x","startedAtMs":1}}"#;

    let event = parse_notification_event(tool_started).unwrap().unwrap();

    assert_eq!(event.event_type, "tool.call.started");
    assert!(event.payload_json.contains("local_shell_call"));
}

#[test]
fn protocol_bootstraps_thread_and_flushes_queued_messages() {
    let mut protocol = CodexSessionProtocol::new("/tmp/workspace".into());

    let bootstrap = protocol.bootstrap_requests();
    assert_eq!(bootstrap.len(), 1);
    assert_eq!(bootstrap[0]["method"], "initialize");

    let queued = protocol
        .enqueue_user_message(UserMessage {
            text: "hello world".into(),
            image_paths: Vec::new(),
        })
        .unwrap();
    assert!(queued.is_empty());

    let init_response = r#"{"jsonrpc":"2.0","id":"agent-dock-initialize-1","result":{}}"#;
    let init_result = protocol.handle_server_line(init_response).unwrap();
    assert_eq!(init_result.outgoing.len(), 1);
    assert_eq!(init_result.outgoing[0]["method"], "thread/start");

    let thread_response = r#"{"jsonrpc":"2.0","id":"agent-dock-thread-start-2","result":{"thread":{"id":"thread-1"}}}"#;
    let thread_result = protocol.handle_server_line(thread_response).unwrap();
    assert_eq!(
        thread_result.runtime_session_id.as_deref(),
        Some("thread-1")
    );
    assert_eq!(thread_result.session_status.as_deref(), Some("running"));
    assert_eq!(thread_result.outgoing.len(), 1);
    assert_eq!(thread_result.outgoing[0]["method"], "turn/start");
    assert_eq!(thread_result.outgoing[0]["params"]["threadId"], "thread-1");
    assert_eq!(
        thread_result.outgoing[0]["params"]["input"][0]["text"],
        "hello world"
    );
}

#[test]
fn protocol_accepts_only_one_user_message_until_turn_completes() {
    let mut protocol = ready_protocol();

    let first = protocol
        .enqueue_user_message(UserMessage {
            text: "first".into(),
            image_paths: Vec::new(),
        })
        .unwrap();
    let second = protocol
        .enqueue_user_message(UserMessage {
            text: "second".into(),
            image_paths: Vec::new(),
        })
        .unwrap();

    assert_eq!(first.len(), 1);
    assert!(second.is_empty());
    assert!(!protocol.can_accept_user_message());

    let completed = protocol
        .handle_server_line(
            r#"{"jsonrpc":"2.0","method":"turn/completed","params":{"turnId":"turn-1","threadId":"thread-1","status":{"type":"completed"}}}"#,
        )
        .unwrap();

    assert!(completed.can_accept_user_message);
    assert!(protocol.can_accept_user_message());
}

#[test]
fn protocol_ignores_notifications_for_other_threads() {
    let mut protocol = ready_protocol();

    let outgoing = protocol
        .enqueue_user_message(UserMessage {
            text: "first".into(),
            image_paths: Vec::new(),
        })
        .unwrap();

    assert_eq!(outgoing.len(), 1);
    assert!(!protocol.can_accept_user_message());

    let foreign = protocol
        .handle_server_line(
            r#"{"jsonrpc":"2.0","method":"turn/completed","params":{"turnId":"turn-foreign","threadId":"thread-foreign","status":{"type":"completed"}}}"#,
        )
        .unwrap();

    assert!(foreign.event.is_none());
    assert!(!foreign.completed_user_message);
    assert!(!foreign.can_accept_user_message);
    assert!(!protocol.can_accept_user_message());
}

#[test]
fn protocol_only_completes_the_matching_in_flight_turn() {
    let mut protocol = ready_protocol();

    let outgoing = protocol
        .enqueue_user_message(UserMessage {
            text: "first".into(),
            image_paths: Vec::new(),
        })
        .unwrap();

    assert_eq!(outgoing.len(), 1);
    assert!(!protocol.can_accept_user_message());

    let started = protocol
        .handle_server_line(
            r#"{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1"}}}"#,
        )
        .unwrap();
    assert!(started.event.is_none());
    assert!(!started.completed_user_message);

    let foreign_completed = protocol
        .handle_server_line(
            r#"{"jsonrpc":"2.0","method":"turn/completed","params":{"turnId":"turn-2","threadId":"thread-1","status":{"type":"completed"}}}"#,
        )
        .unwrap();

    assert!(foreign_completed.event.is_some());
    assert!(!foreign_completed.completed_user_message);
    assert!(!foreign_completed.can_accept_user_message);
    assert!(!protocol.can_accept_user_message());

    let matching_completed = protocol
        .handle_server_line(
            r#"{"jsonrpc":"2.0","method":"turn/completed","params":{"turnId":"turn-1","threadId":"thread-1","status":{"type":"completed"}}}"#,
        )
        .unwrap();

    assert!(matching_completed.completed_user_message);
    assert!(matching_completed.can_accept_user_message);
    assert!(protocol.can_accept_user_message());
}

#[test]
fn attached_protocol_bootstraps_resume_and_flushes_queued_messages() {
    let mut protocol =
        CodexSessionProtocol::new_attached("/tmp/workspace".into(), "thread-1".into());

    let bootstrap = protocol.bootstrap_requests();
    assert_eq!(bootstrap.len(), 1);
    assert_eq!(bootstrap[0]["method"], "initialize");

    let queued = protocol
        .enqueue_user_message(UserMessage {
            text: "hello world".into(),
            image_paths: Vec::new(),
        })
        .unwrap();
    assert!(queued.is_empty());

    let init_response = r#"{"jsonrpc":"2.0","id":"agent-dock-initialize-1","result":{}}"#;
    let init_result = protocol.handle_server_line(init_response).unwrap();
    assert_eq!(init_result.outgoing.len(), 1);
    assert_eq!(init_result.outgoing[0]["method"], "thread/resume");

    let thread_response = r#"{"jsonrpc":"2.0","id":"agent-dock-thread-resume-2","result":{"thread":{"id":"thread-1"}}}"#;
    let thread_result = protocol.handle_server_line(thread_response).unwrap();
    assert_eq!(
        thread_result.runtime_session_id.as_deref(),
        Some("thread-1")
    );
    assert_eq!(thread_result.session_status.as_deref(), Some("running"));
    assert_eq!(thread_result.outgoing.len(), 1);
    assert_eq!(thread_result.outgoing[0]["method"], "turn/start");
    assert_eq!(thread_result.outgoing[0]["params"]["threadId"], "thread-1");
}

#[test]
fn attached_protocol_falls_back_to_thread_start_when_resume_returns_no_thread_id() {
    let mut protocol =
        CodexSessionProtocol::new_attached("/tmp/workspace".into(), "thread-stale".into());

    protocol.bootstrap_requests();
    protocol
        .enqueue_user_message(UserMessage {
            text: "hello world".into(),
            image_paths: Vec::new(),
        })
        .unwrap();

    let init_response = r#"{"jsonrpc":"2.0","id":"agent-dock-initialize-1","result":{}}"#;
    let init_result = protocol.handle_server_line(init_response).unwrap();
    assert_eq!(init_result.outgoing[0]["method"], "thread/resume");

    let resume_response =
        r#"{"jsonrpc":"2.0","id":"agent-dock-thread-resume-2","result":{"thread":{}}}"#;
    let resume_result = protocol.handle_server_line(resume_response).unwrap();
    assert_eq!(resume_result.outgoing.len(), 1);
    assert_eq!(resume_result.outgoing[0]["method"], "thread/start");
    assert!(resume_result.runtime_session_id.is_none());

    let start_response = r#"{"jsonrpc":"2.0","id":"agent-dock-thread-start-3","result":{"thread":{"id":"thread-fresh"}}}"#;
    let start_result = protocol.handle_server_line(start_response).unwrap();
    assert_eq!(
        start_result.runtime_session_id.as_deref(),
        Some("thread-fresh")
    );
    assert_eq!(start_result.outgoing.len(), 1);
    assert_eq!(start_result.outgoing[0]["method"], "turn/start");
    assert_eq!(
        start_result.outgoing[0]["params"]["threadId"],
        "thread-fresh"
    );
}

#[test]
fn protocol_only_marks_failed_after_failed_turn_completion() {
    let mut protocol = ready_protocol();

    let system_error = r#"{"jsonrpc":"2.0","method":"thread/status/changed","params":{"status":{"type":"systemError"},"threadId":"thread-1"}}"#;
    let failed_turn = r#"{"jsonrpc":"2.0","method":"turn/completed","params":{"turnId":"turn-1","threadId":"thread-1","status":{"type":"failed","message":"compact exploded"}}}"#;

    let system_error_result = protocol.handle_server_line(system_error).unwrap();
    let failed_turn_result = protocol.handle_server_line(failed_turn).unwrap();

    assert!(system_error_result.session_status.is_none());
    assert_eq!(failed_turn_result.session_status.as_deref(), Some("failed"));
    assert!(
        failed_turn_result
            .event
            .unwrap()
            .payload_json
            .contains("compact exploded")
    );
}

#[test]
fn protocol_keeps_error_notifications_as_events_without_marking_session_dead() {
    let mut protocol = ready_protocol();
    let error = r#"{"jsonrpc":"2.0","method":"error","params":{"message":"temporary reconnect","willRetry":true,"threadId":"thread-1"}}"#;

    let result = protocol.handle_server_line(error).unwrap();

    assert!(result.runtime_session_id.is_none());
    assert!(result.session_status.is_none());
    let event = result.event.unwrap();
    assert_eq!(event.event_type, "session.error");
    assert!(event.payload_json.contains("temporary reconnect"));
}

#[test]
fn protocol_marks_non_terminal_runtime_errors_as_recoverable_health() {
    let mut protocol = ready_protocol();
    let error = r#"{"jsonrpc":"2.0","method":"error","params":{"message":"temporary reconnect","willRetry":true,"threadId":"thread-1"}}"#;

    let result = protocol.handle_server_line(error).unwrap();

    assert_eq!(result.runtime_health.as_deref(), Some("recoverable_error"));
    assert_eq!(
        result
            .runtime_error_kind
            .as_ref()
            .and_then(|kind| kind.as_deref()),
        Some("transport")
    );
    assert_eq!(
        result
            .runtime_error_message
            .as_ref()
            .and_then(|message| message.as_deref()),
        Some("temporary reconnect")
    );
    assert!(result.session_status.is_none());
}

#[test]
fn protocol_maps_compact_slash_command_to_real_thread_compact_request() {
    let mut protocol = ready_protocol();

    let outgoing = protocol
        .enqueue_user_message(UserMessage {
            text: "/compact".into(),
            image_paths: Vec::new(),
        })
        .unwrap();

    assert_eq!(outgoing.len(), 1);
    assert_eq!(outgoing[0]["method"], "thread/compact/start");
    assert_eq!(outgoing[0]["params"]["threadId"], "thread-1");

    let response = format!(
        r#"{{"jsonrpc":"2.0","id":{},"result":{{}}}}"#,
        serde_json::to_string(outgoing[0]["id"].as_str().unwrap()).unwrap()
    );
    let result = protocol.handle_server_line(&response).unwrap();

    let event = result.event.unwrap();
    assert_eq!(event.event_type, "assistant.message");
    assert!(event.payload_json.contains("Compaction started"));
}

#[test]
fn protocol_maps_goal_query_to_real_thread_goal_get_request() {
    let mut protocol = ready_protocol();

    let outgoing = protocol
        .enqueue_user_message(UserMessage {
            text: "/goal".into(),
            image_paths: Vec::new(),
        })
        .unwrap();

    assert_eq!(outgoing.len(), 1);
    assert_eq!(outgoing[0]["method"], "thread/goal/get");
    assert_eq!(outgoing[0]["params"]["threadId"], "thread-1");

    let response = format!(
        r#"{{"jsonrpc":"2.0","id":{},"result":{{"goal":{{"threadId":"thread-1","objective":"Ship slash commands","status":"active","tokenBudget":null,"tokensUsed":12,"timeUsedSeconds":3,"createdAt":1,"updatedAt":2}}}}}}"#,
        serde_json::to_string(outgoing[0]["id"].as_str().unwrap()).unwrap()
    );
    let result = protocol.handle_server_line(&response).unwrap();

    let event = result.event.unwrap();
    assert_eq!(event.event_type, "assistant.message");
    assert!(event.payload_json.contains("Ship slash commands"));
    assert!(event.payload_json.contains("active"));
}

#[test]
fn protocol_maps_goal_clear_to_real_thread_goal_clear_request() {
    let mut protocol = ready_protocol();

    let outgoing = protocol
        .enqueue_user_message(UserMessage {
            text: "/goal clear".into(),
            image_paths: Vec::new(),
        })
        .unwrap();

    assert_eq!(outgoing.len(), 1);
    assert_eq!(outgoing[0]["method"], "thread/goal/clear");
    assert_eq!(outgoing[0]["params"]["threadId"], "thread-1");

    let response = format!(
        r#"{{"jsonrpc":"2.0","id":{},"result":{{"cleared":true}}}}"#,
        serde_json::to_string(outgoing[0]["id"].as_str().unwrap()).unwrap()
    );
    let result = protocol.handle_server_line(&response).unwrap();

    let event = result.event.unwrap();
    assert_eq!(event.event_type, "assistant.message");
    assert!(event.payload_json.contains("Goal cleared"));
}

#[test]
fn protocol_maps_goal_text_to_real_thread_goal_set_request() {
    let mut protocol = ready_protocol();

    let outgoing = protocol
        .enqueue_user_message(UserMessage {
            text: "/goal Finish command support".into(),
            image_paths: Vec::new(),
        })
        .unwrap();

    assert_eq!(outgoing.len(), 1);
    assert_eq!(outgoing[0]["method"], "thread/goal/set");
    assert_eq!(outgoing[0]["params"]["threadId"], "thread-1");
    assert_eq!(outgoing[0]["params"]["objective"], "Finish command support");

    let response = format!(
        r#"{{"jsonrpc":"2.0","id":{},"result":{{"goal":{{"threadId":"thread-1","objective":"Finish command support","status":"active","tokenBudget":null,"tokensUsed":0,"timeUsedSeconds":0,"createdAt":1,"updatedAt":2}}}}}}"#,
        serde_json::to_string(outgoing[0]["id"].as_str().unwrap()).unwrap()
    );
    let result = protocol.handle_server_line(&response).unwrap();

    let event = result.event.unwrap();
    assert_eq!(event.event_type, "assistant.message");
    assert!(event.payload_json.contains("Goal set"));
    assert!(event.payload_json.contains("Finish command support"));
}

#[test]
fn protocol_maps_command_errors_to_visible_assistant_messages() {
    let mut protocol = ready_protocol();

    let outgoing = protocol
        .enqueue_user_message(UserMessage {
            text: "/compact".into(),
            image_paths: Vec::new(),
        })
        .unwrap();

    let response = format!(
        r#"{{"jsonrpc":"2.0","id":{},"error":{{"code":-32000,"message":"thread is busy"}}}}"#,
        serde_json::to_string(outgoing[0]["id"].as_str().unwrap()).unwrap()
    );
    let result = protocol.handle_server_line(&response).unwrap();

    let event = result.event.unwrap();
    assert_eq!(event.event_type, "assistant.message");
    assert!(event.payload_json.contains("Command failed"));
    assert!(event.payload_json.contains("thread is busy"));
    assert_eq!(result.runtime_health.as_deref(), Some("recoverable_error"));
    assert_eq!(
        result
            .runtime_error_kind
            .as_ref()
            .and_then(|kind| kind.as_deref()),
        Some("runtime")
    );
    assert_eq!(
        result
            .runtime_error_message
            .as_ref()
            .and_then(|message| message.as_deref()),
        Some("thread is busy")
    );
    assert!(result.session_status.is_none());
}

#[test]
fn protocol_classifies_transport_and_provider_error_kinds() {
    let mut protocol = ready_protocol();

    let notification = protocol
        .handle_server_line(
            r#"{"jsonrpc":"2.0","method":"error","params":{"message":"temporary reconnect timeout","willRetry":true,"threadId":"thread-1"}}"#,
        )
        .unwrap();
    assert_eq!(
        notification
            .runtime_error_kind
            .as_ref()
            .and_then(|kind| kind.as_deref()),
        Some("transport")
    );

    let outgoing = protocol
        .enqueue_user_message(UserMessage {
            text: "/compact".into(),
            image_paths: Vec::new(),
        })
        .unwrap();
    let response = format!(
        r#"{{"jsonrpc":"2.0","id":{},"error":{{"code":-32000,"message":"compact service returned 502"}}}}"#,
        serde_json::to_string(outgoing[0]["id"].as_str().unwrap()).unwrap()
    );
    let result = protocol.handle_server_line(&response).unwrap();
    assert_eq!(
        result
            .runtime_error_kind
            .as_ref()
            .and_then(|kind| kind.as_deref()),
        Some("provider")
    );
}

#[test]
fn protocol_keeps_unknown_slash_commands_as_normal_turns() {
    let mut protocol = ready_protocol();

    let outgoing = protocol
        .enqueue_user_message(UserMessage {
            text: "/resume".into(),
            image_paths: Vec::new(),
        })
        .unwrap();

    assert_eq!(outgoing.len(), 1);
    assert_eq!(outgoing[0]["method"], "turn/start");
    assert_eq!(outgoing[0]["params"]["input"][0]["text"], "/resume");
}

#[test]
fn protocol_keeps_commands_with_images_as_normal_turns() {
    let mut protocol = ready_protocol();

    let outgoing = protocol
        .enqueue_user_message(UserMessage {
            text: "/compact".into(),
            image_paths: vec!["/tmp/screenshot.png".into()],
        })
        .unwrap();

    assert_eq!(outgoing.len(), 1);
    assert_eq!(outgoing[0]["method"], "turn/start");
    assert_eq!(outgoing[0]["params"]["input"][0]["text"], "/compact");
    assert_eq!(outgoing[0]["params"]["input"][1]["type"], "localImage");
}

fn ready_protocol() -> CodexSessionProtocol {
    let mut protocol = CodexSessionProtocol::new("/tmp/workspace".into());
    protocol.bootstrap_requests();
    protocol
        .handle_server_line(r#"{"jsonrpc":"2.0","id":"agent-dock-initialize-1","result":{}}"#)
        .unwrap();
    protocol
        .handle_server_line(
            r#"{"jsonrpc":"2.0","id":"agent-dock-thread-start-2","result":{"thread":{"id":"thread-1"}}}"#,
        )
        .unwrap();
    protocol
}
