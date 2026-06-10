use agent_workspace_daemon::adapters::claude::parse_claude_stream_line;

#[test]
fn claude_stream_maps_assistant_and_thinking_events() {
    let thinking =
        r#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"plan first"}]}}"#;
    let message = r#"{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}"#;

    let thinking_event = parse_claude_stream_line(thinking).unwrap().unwrap();
    let message_event = parse_claude_stream_line(message).unwrap().unwrap();

    assert_eq!(thinking_event.event_type, "assistant.thinking.delta");
    assert_eq!(message_event.event_type, "assistant.message");
}
