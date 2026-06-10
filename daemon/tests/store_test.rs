use agent_workspace_daemon::session::store::SqliteSessionStore;

#[tokio::test]
async fn store_builds_session_snapshot_in_event_order() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let session_id = store
        .create_session(
            "workspace".into(),
            "repo".into(),
            "managed".into(),
            "placeholder".into(),
        )
        .await
        .unwrap();

    store
        .append_event(&session_id, "session.created", r#"{"status":"created"}"#)
        .await
        .unwrap();
    store
        .append_event(&session_id, "user.message", r#"{"text":"hello"}"#)
        .await
        .unwrap();

    let snapshot = store.load_snapshot(&session_id).await.unwrap();

    assert_eq!(snapshot.session.id, session_id);
    assert_eq!(snapshot.events.len(), 2);
    assert_eq!(snapshot.events[0].event_type, "session.created");
    assert_eq!(snapshot.events[1].event_type, "user.message");
}
