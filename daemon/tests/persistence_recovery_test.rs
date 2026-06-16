use sqlx::{Connection, Executor, SqliteConnection};
use tempfile::tempdir;

use agent_dock_daemon::session::store::SqliteSessionStore;

#[tokio::test]
async fn persistence_recovery_file_backed_store_recovers_sessions_and_events_after_reopen() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("agent-dock.sqlite3");

    let store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let session_id = store
        .create_session(
            "usr_workspace".into(),
            "workspace".into(),
            "repo".into(),
            "managed".into(),
            "codex".into(),
            Some("Launch Pad".into()),
        )
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
    assert_eq!(snapshot.session.title.as_deref(), Some("Launch Pad"));
    assert_eq!(snapshot.events.len(), 1);
}

#[tokio::test]
async fn persistence_recovery_session_service_lists_recovered_sessions_from_store() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("agent-dock.sqlite3");

    let store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    store
        .create_session(
            "usr_workspace".into(),
            "workspace".into(),
            "repo".into(),
            "managed".into(),
            "codex".into(),
            None,
        )
        .await
        .unwrap();
    drop(store);

    let reopened = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let service = agent_dock_daemon::session::service::SessionService::new(reopened);

    let sessions = service.list_sessions().await.unwrap();

    assert_eq!(sessions.len(), 1);
}

#[tokio::test]
async fn persistence_recovery_file_backed_store_upgrades_legacy_database_and_loads_null_title() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("agent-dock.sqlite3");
    let database_url = format!("sqlite://{}", db_path.display());
    std::fs::File::create(&db_path).unwrap();

    let mut connection = SqliteConnection::connect(&database_url).await.unwrap();
    connection.execute(include_str!("../migrations/0001_init.sql")).await.unwrap();
    connection
        .execute(
            r#"
            create table _sqlx_migrations (
              version bigint primary key,
              description text not null,
              installed_on timestamp not null default current_timestamp,
              success boolean not null,
              checksum blob not null,
              execution_time bigint not null
            )
            "#,
        )
        .await
        .unwrap();
    sqlx::query(
        r#"
        insert into _sqlx_migrations (version, description, success, checksum, execution_time)
        values (?1, ?2, ?3, ?4, ?5)
        "#,
    )
        .bind(1_i64)
        .bind("init")
        .bind(true)
        .bind(vec![
            184, 209, 152, 56, 42, 75, 33, 77, 117, 24, 218, 73, 94, 31, 215, 7, 197, 170,
            114, 175, 90, 12, 252, 90, 223, 100, 103, 199, 137, 153, 193, 12, 199, 245, 55,
            242, 218, 247, 220, 177, 145, 171, 232, 125, 9, 188, 156, 72,
        ])
        .bind(0_i64)
        .execute(&mut connection)
        .await
        .unwrap();
    connection
        .execute(
            r#"
            insert into sessions
              (id, root_id, workspace_path, source_kind, agent_kind, runtime_session_id, status, created_at, updated_at)
            values
              ('sess_legacy', 'workspace', 'repo', 'managed', 'claude', null, 'created', datetime('now'), datetime('now'))
            "#,
        )
        .await
        .unwrap();
    connection.close().await.unwrap();

    let store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let snapshot = store.load_snapshot("sess_legacy").await.unwrap();

    assert_eq!(snapshot.session.id, "sess_legacy");
    assert_eq!(snapshot.session.title, None);
    assert_eq!(snapshot.session.owner_user_id, "usr_workspace");
}
