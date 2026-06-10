use tempfile::tempdir;

use agent_workspace_daemon::session::store::SqliteSessionStore;

#[tokio::test]
async fn file_backed_store_recovers_sessions_and_events_after_reopen() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("agent-workspace.sqlite3");

    let store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let session_id = store
        .create_session("workspace".into(), "repo".into(), "managed".into(), "codex".into())
        .await
        .unwrap();
    store
        .append_event(&session_id, "session.created", r#"{"status":"created"}"#)
        .await
        .unwrap();

    drop(store);

    let reopened = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let snapshot = reopened.load_snapshot(&session_id).await.unwrap();

    assert_eq!(snapshot.session.id, session_id);
    assert_eq!(snapshot.events.len(), 1);
}

#[tokio::test]
async fn session_service_lists_recovered_sessions_from_store() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("agent-workspace.sqlite3");

    let store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    store
        .create_session("workspace".into(), "repo".into(), "managed".into(), "codex".into())
        .await
        .unwrap();
    drop(store);

    let reopened = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let service = agent_workspace_daemon::session::service::SessionService::new(reopened);

    let sessions = service.list_sessions().await.unwrap();

    assert_eq!(sessions.len(), 1);
}
