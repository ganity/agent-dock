use agent_dock_daemon::adapters::claude::parse_claude_stream_line;

#[test]
fn claude_stream_maps_assistant_and_thinking_events() {
    let thinking = r#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"plan first"}]}}"#;
    let message = r#"{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}"#;

    let thinking_event = parse_claude_stream_line(thinking).unwrap().unwrap();
    let message_event = parse_claude_stream_line(message).unwrap().unwrap();

    assert_eq!(thinking_event.event_type, "assistant.thinking.delta");
    assert_eq!(message_event.event_type, "assistant.message");
}

#[test]
fn claude_stream_maps_partial_text_and_thinking_deltas() {
    let text_delta = r#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}}"#;
    let thinking_delta = r#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"plan"}}}"#;

    let text_event = parse_claude_stream_line(text_delta).unwrap().unwrap();
    let thinking_event = parse_claude_stream_line(thinking_delta).unwrap().unwrap();

    assert_eq!(text_event.event_type, "assistant.message");
    assert!(text_event.payload_json.contains("hello"));
    assert_eq!(thinking_event.event_type, "assistant.thinking.delta");
    assert!(thinking_event.payload_json.contains("plan"));
}
