use agent_workspace_daemon::adapters::codex_protocol::{
    build_initialize_request, build_thread_start_request, build_turn_start_request, parse_notification_event,
    CodexSessionProtocol,
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

#[test]
fn protocol_bootstraps_thread_and_flushes_queued_messages() {
    let mut protocol = CodexSessionProtocol::new("/tmp/workspace".into());

    let bootstrap = protocol.bootstrap_requests();
    assert_eq!(bootstrap.len(), 1);
    assert_eq!(bootstrap[0]["method"], "initialize");

    let queued = protocol.enqueue_user_message("hello world".into()).unwrap();
    assert!(queued.is_empty());

    let init_response = r#"{"jsonrpc":"2.0","id":"agent-workspace-initialize-1","result":{}}"#;
    let init_result = protocol.handle_server_line(init_response).unwrap();
    assert_eq!(init_result.outgoing.len(), 1);
    assert_eq!(init_result.outgoing[0]["method"], "thread/start");

    let thread_response = r#"{"jsonrpc":"2.0","id":"agent-workspace-thread-start-2","result":{"thread":{"id":"thread-1"}}}"#;
    let thread_result = protocol.handle_server_line(thread_response).unwrap();
    assert_eq!(thread_result.outgoing.len(), 1);
    assert_eq!(thread_result.outgoing[0]["method"], "turn/start");
    assert_eq!(thread_result.outgoing[0]["params"]["threadId"], "thread-1");
    assert_eq!(thread_result.outgoing[0]["params"]["input"][0]["text"], "hello world");
}
