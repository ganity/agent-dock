use agent_workspace_daemon::adapters::codex::parse_codex_rpc_line;

#[test]
fn codex_rpc_maps_message_and_file_change_events() {
    let message = r#"{"jsonrpc":"2.0","method":"session/message","params":{"text":"applied fix"}}"#;
    let file_change =
        r#"{"jsonrpc":"2.0","method":"session/fileChangeReported","params":{"files":["src/app.rs"]}}"#;

    let message_event = parse_codex_rpc_line(message).unwrap().unwrap();
    let change_event = parse_codex_rpc_line(file_change).unwrap().unwrap();

    assert_eq!(message_event.event_type, "assistant.message");
    assert_eq!(change_event.event_type, "file.change.reported");
}
