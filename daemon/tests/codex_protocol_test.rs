use agent_dock_daemon::adapters::codex_protocol::{
    build_initialize_request, build_thread_resume_request, build_thread_start_request,
    build_turn_start_request, parse_notification_event, CodexSessionProtocol, UserMessage,
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
    assert_eq!(thread_result.outgoing.len(), 1);
    assert_eq!(thread_result.outgoing[0]["method"], "turn/start");
    assert_eq!(thread_result.outgoing[0]["params"]["threadId"], "thread-1");
    assert_eq!(
        thread_result.outgoing[0]["params"]["input"][0]["text"],
        "hello world"
    );
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
    assert_eq!(thread_result.outgoing.len(), 1);
    assert_eq!(thread_result.outgoing[0]["method"], "turn/start");
    assert_eq!(thread_result.outgoing[0]["params"]["threadId"], "thread-1");
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
