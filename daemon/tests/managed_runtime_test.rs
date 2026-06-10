use std::{sync::Arc, time::Duration};

use agent_workspace_daemon::{
    adapters::process::{spawn_command, LaunchCommand},
    session::{service::SessionService, store::SqliteSessionStore},
};

#[tokio::test]
async fn managed_claude_session_appends_parsed_events_from_process_output() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let recorded = Arc::new(std::sync::Mutex::new(Vec::<LaunchCommand>::new()));
    let recorded_for_spawner = recorded.clone();
    let spawner = Arc::new(move |command: LaunchCommand| {
        recorded_for_spawner.lock().unwrap().push(command);
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "printf '%s\n%s\n%s\n' \
                 '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"thinking\",\"thinking\":\"plan first\"}]}}' \
                 '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}' \
                 '{\"type\":\"result\",\"session_id\":\"claude-thread-1\",\"result\":\"done\"}'".into(),
            ],
        })
    });

    let service = SessionService::new_with_spawner(store, spawner);
    let session_id = service
        .create_managed_session("workspace".into(), "repo".into(), "claude".into())
        .await
        .unwrap();

    service
        .send_user_message(&session_id, "hello from user".into())
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(50)).await;

    let snapshot = service.load_snapshot(&session_id).await.unwrap();

    assert!(
        snapshot
            .events
            .iter()
            .any(|event| event.event_type == "assistant.thinking.delta")
    );
    assert!(
        snapshot
            .events
            .iter()
            .any(|event| event.event_type == "assistant.message")
    );
    assert_eq!(snapshot.session.runtime_session_id.as_deref(), Some("claude-thread-1"));

    service
        .send_user_message(&session_id, "follow up".into())
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(50)).await;

    let launches = recorded.lock().unwrap();
    assert_eq!(launches.len(), 2);
    assert!(!launches[0].args.iter().any(|arg| arg == "--resume"));
    assert!(launches[1].args.iter().any(|arg| arg == "--resume"));
    assert!(launches[1].args.iter().any(|arg| arg == "claude-thread-1"));
}

#[tokio::test]
async fn managed_codex_session_bootstraps_protocol_and_flushes_user_message() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let spawner = Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-workspace-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _thread; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-workspace-thread-start-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 IFS= read -r _turn; printf '%s\n' '{\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"reply\",\"itemId\":\"i1\",\"threadId\":\"thread-1\",\"turnId\":\"turn-1\"}}'".into(),
            ],
        })
    });

    let service = SessionService::new_with_spawner(store, spawner);
    let session_id = service
        .create_managed_session("workspace".into(), "repo".into(), "codex".into())
        .await
        .unwrap();

    service
        .send_user_message(&session_id, "hello from user".into())
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(100)).await;

    let snapshot = service.load_snapshot(&session_id).await.unwrap();

    assert!(
        snapshot
            .events
            .iter()
            .any(|event| event.event_type == "user.message")
    );
    assert!(
        snapshot
            .events
            .iter()
            .any(|event| event.event_type == "assistant.message" && event.payload_json.contains("reply"))
    );
}
