use agent_dock_daemon::session::store::SqliteSessionStore;

#[tokio::test]
async fn store_builds_session_snapshot_in_event_order() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let session_id = store
        .create_session(
            "usr_workspace".into(),
            "workspace".into(),
            "repo".into(),
            "managed".into(),
            "placeholder".into(),
            None,
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

#[tokio::test]
async fn store_persists_runtime_health_and_error_message() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let session_id = store
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

    let initial = store.load_snapshot(&session_id).await.unwrap();
    assert_eq!(initial.session.runtime_health, "unknown");
    assert_eq!(initial.session.runtime_error_kind, None);
    assert_eq!(initial.session.runtime_error_message, None);

    store
        .update_runtime_health(
            &session_id,
            "recoverable_error",
            Some("transport"),
            Some("temporary reconnect"),
        )
        .await
        .unwrap();

    let updated = store.load_snapshot(&session_id).await.unwrap();
    assert_eq!(updated.session.runtime_health, "recoverable_error");
    assert_eq!(
        updated.session.runtime_error_kind.as_deref(),
        Some("transport")
    );
    assert_eq!(
        updated.session.runtime_error_message.as_deref(),
        Some("temporary reconnect")
    );
}

#[tokio::test]
async fn store_persists_pending_user_messages_in_order_until_deleted() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let session_id = store
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

    let (_, first_id) = store
        .append_user_message_and_enqueue_pending(
            &session_id,
            None,
            "first".into(),
            &["/tmp/one.png".into()],
        )
        .await
        .unwrap();
    let (_, second_id) = store
        .append_user_message_and_enqueue_pending(&session_id, None, "second".into(), &[])
        .await
        .unwrap();

    let pending = store.pending_user_messages(&session_id).await.unwrap();
    assert_eq!(pending.len(), 2);
    assert_eq!(pending[0].id, first_id);
    assert_eq!(pending[0].text, "first");
    assert_eq!(pending[0].image_paths, vec!["/tmp/one.png"]);
    assert_eq!(pending[1].id, second_id);
    assert_eq!(pending[1].text, "second");
    assert!(pending[1].image_paths.is_empty());

    store
        .delete_pending_user_message(&session_id, first_id)
        .await
        .unwrap();

    let remaining = store.pending_user_messages(&session_id).await.unwrap();
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].id, second_id);

    let snapshot = store.load_snapshot(&session_id).await.unwrap();
    assert_eq!(
        snapshot
            .events
            .iter()
            .filter(|event| event.event_type == "user.message")
            .count(),
        2
    );
}

#[tokio::test]
async fn store_tracks_in_flight_pending_user_message_until_acknowledged() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let session_id = store
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

    let (_, first_id) = store
        .append_user_message_and_enqueue_pending(&session_id, None, "first".into(), &[])
        .await
        .unwrap();
    let (_, second_id) = store
        .append_user_message_and_enqueue_pending(&session_id, None, "second".into(), &[])
        .await
        .unwrap();

    let claimed = store
        .claim_next_pending_user_message(&session_id)
        .await
        .unwrap()
        .unwrap();

    assert_eq!(claimed.id, first_id);
    assert_eq!(claimed.text, "first");
    let pending = store.pending_user_messages(&session_id).await.unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].id, second_id);
    assert_eq!(
        store
            .in_flight_user_message(&session_id)
            .await
            .unwrap()
            .unwrap()
            .id,
        first_id
    );

    store
        .reset_in_flight_user_messages(&session_id)
        .await
        .unwrap();
    let pending_after_reset = store.pending_user_messages(&session_id).await.unwrap();
    assert_eq!(
        pending_after_reset
            .iter()
            .map(|message| message.id)
            .collect::<Vec<_>>(),
        vec![first_id, second_id]
    );

    let claimed_again = store
        .claim_next_pending_user_message(&session_id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(claimed_again.id, first_id);
    store
        .ack_in_flight_user_message(&session_id, first_id)
        .await
        .unwrap();

    assert!(
        store
            .in_flight_user_message(&session_id)
            .await
            .unwrap()
            .is_none()
    );
    let remaining = store.pending_user_messages(&session_id).await.unwrap();
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].id, second_id);
}

#[tokio::test]
async fn store_persists_message_receipts_for_client_dedup() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let session_id = store
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

    assert!(
        store
            .message_receipt_event_id(&session_id, "cli_1")
            .await
            .unwrap()
            .is_none()
    );

    store
        .record_message_receipt(&session_id, "cli_1", 42)
        .await
        .unwrap();

    assert_eq!(
        store
            .message_receipt_event_id(&session_id, "cli_1")
            .await
            .unwrap(),
        Some(42)
    );
}
