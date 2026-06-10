use agent_workspace_daemon::adapters::codex_protocol::{
    build_initialize_request, build_thread_start_request, build_turn_start_request,
    parse_notification_event,
};

#[test]
fn initialize_request_uses_initialize_method() {
    let request = build_initialize_request("req-1");

    assert_eq!(request["jsonrpc"], "2.0");
    assert_eq!(request["id"], "req-1");
    assert_eq!(request["method"], "initialize");
}

#[test]
fn thread_start_request_uses_thread_start_method_and_cwd() {
    let request = build_thread_start_request("req-2", "/tmp/workspace");

    assert_eq!(request["method"], "thread/start");
    assert_eq!(request["params"]["cwd"], "/tmp/workspace");
}

#[test]
fn turn_start_request_uses_text_user_input_shape() {
    let request = build_turn_start_request("req-3", "thread-1", "hello world");

    assert_eq!(request["method"], "turn/start");
    assert_eq!(request["params"]["threadId"], "thread-1");
    assert_eq!(request["params"]["input"][0]["type"], "text");
    assert_eq!(request["params"]["input"][0]["text"], "hello world");
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
