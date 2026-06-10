use agent_workspace_daemon::session::store::SqliteSessionStore;

#[tokio::test]
async fn store_lists_sessions_and_events_after_cursor() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let first = store
        .create_session(
            "workspace".into(),
            "repo-a".into(),
            "managed".into(),
            "claude".into(),
        )
        .await
        .unwrap();
    let second = store
        .create_session(
            "workspace".into(),
            "repo-b".into(),
            "managed".into(),
            "codex".into(),
        )
        .await
        .unwrap();

    store
        .append_event(&first, "session.created", r#"{"status":"created"}"#)
        .await
        .unwrap();
    store
        .append_event(&first, "assistant.message", r#"{"text":"hello"}"#)
        .await
        .unwrap();
    store
        .append_event(&second, "session.created", r#"{"status":"created"}"#)
        .await
        .unwrap();

    let sessions = store.list_sessions().await.unwrap();
    let after_first = store.events_after(&first, 1).await.unwrap();

    assert_eq!(sessions.len(), 2);
    assert_eq!(after_first.len(), 1);
    assert_eq!(after_first[0].event_type, "assistant.message");
}
