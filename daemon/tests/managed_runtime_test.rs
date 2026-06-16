use std::{sync::Arc, time::Duration};

use agent_dock_daemon::{
    adapters::process::{LaunchCommand, spawn_command},
    session::{service::SessionService, store::SqliteSessionStore},
};
use tempfile::tempdir;

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
        .create_managed_session("workspace".into(), "repo".into(), "claude".into(), None)
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
    assert_eq!(
        snapshot.session.runtime_session_id.as_deref(),
        Some("claude-thread-1")
    );

    service
        .send_user_message(&session_id, "follow up".into())
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(50)).await;

    let launches = recorded.lock().unwrap();
    assert!(
        launches[0]
            .args
            .iter()
            .any(|arg| arg == "--include-partial-messages")
    );
    assert_eq!(launches.len(), 2);
    assert!(!launches[0].args.iter().any(|arg| arg == "--resume"));
    assert!(launches[1].args.iter().any(|arg| arg == "--resume"));
    assert!(launches[1].args.iter().any(|arg| arg == "claude-thread-1"));
}

#[tokio::test]
async fn managed_claude_session_includes_image_paths_in_prompt() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let recorded = Arc::new(std::sync::Mutex::new(Vec::<LaunchCommand>::new()));
    let recorded_for_spawner = recorded.clone();
    let spawner = Arc::new(move |command: LaunchCommand| {
        recorded_for_spawner.lock().unwrap().push(command);
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "printf '%s\n' '{\"type\":\"result\",\"session_id\":\"claude-thread-1\",\"result\":\"done\"}'".into(),
            ],
        })
    });

    let service = SessionService::new_with_spawner(store, spawner);
    let session_id = service
        .create_managed_session("workspace".into(), "repo".into(), "claude".into(), None)
        .await
        .unwrap();

    service
        .send_user_message_with_images(
            &session_id,
            "describe the screenshot".into(),
            vec!["/tmp/agent-dock/screenshot.png".into()],
        )
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(50)).await;

    let launches = recorded.lock().unwrap();
    let prompt = launches[0].args.last().unwrap();
    assert!(prompt.contains("describe the screenshot"));
    assert!(prompt.contains("Analyze these images"));
    assert!(prompt.contains("/tmp/agent-dock/screenshot.png"));
}

#[tokio::test]
async fn managed_codex_session_bootstraps_protocol_and_flushes_user_message() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let spawner = Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _thread; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-start-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 IFS= read -r _turn; printf '%s\n' '{\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"reply\",\"itemId\":\"i1\",\"threadId\":\"thread-1\",\"turnId\":\"turn-1\"}}'".into(),
            ],
        })
    });

    let service = SessionService::new_with_spawner(store, spawner);
    let session_id = service
        .create_managed_session("workspace".into(), "repo".into(), "codex".into(), None)
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
    assert!(snapshot.events.iter().any(
        |event| event.event_type == "assistant.message" && event.payload_json.contains("reply")
    ));
}

#[tokio::test]
async fn managed_codex_session_recovers_after_service_restart_and_resumes_thread() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("agent-dock.sqlite3");
    let recorded = Arc::new(std::sync::Mutex::new(Vec::<LaunchCommand>::new()));
    let launch_count = Arc::new(std::sync::Mutex::new(0usize));
    let recorded_for_spawner = recorded.clone();
    let launch_count_for_spawner = launch_count.clone();
    let spawner = Arc::new(move |command: LaunchCommand| {
        recorded_for_spawner.lock().unwrap().push(command);
        let mut launch_count = launch_count_for_spawner.lock().unwrap();
        *launch_count += 1;

        match *launch_count {
            1 => spawn_command(LaunchCommand {
                program: "sh".into(),
                args: vec![
                    "-lc".into(),
                    "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                     IFS= read -r _thread; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-start-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                     printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"thread/status/changed\",\"params\":{\"status\":{\"type\":\"active\"},\"threadId\":\"thread-1\"}}'; \
                     IFS= read -r _turn; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"first-reply\",\"threadId\":\"thread-1\",\"turnId\":\"turn-1\"}}'".into(),
                ],
            }),
            _ => spawn_command(LaunchCommand {
                program: "sh".into(),
                args: vec![
                    "-lc".into(),
                    "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                     IFS= read -r _resume; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-resume-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                     printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"thread/status/changed\",\"params\":{\"status\":{\"type\":\"active\"},\"threadId\":\"thread-1\"}}'; \
                     IFS= read -r _turn; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"second-reply\",\"threadId\":\"thread-1\",\"turnId\":\"turn-2\"}}'".into(),
                ],
            }),
        }
    });

    let first_store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let first_service = SessionService::new_with_spawner(first_store, spawner.clone());
    let session_id = first_service
        .create_managed_session("workspace".into(), "repo".into(), "codex".into(), None)
        .await
        .unwrap();

    first_service
        .send_user_message(&session_id, "hello from user".into())
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(100)).await;
    drop(first_service);

    let reopened_store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let reopened_service = SessionService::new_with_spawner(reopened_store, spawner);
    reopened_service
        .send_user_message(&session_id, "after restart".into())
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(100)).await;

    let snapshot = reopened_service.load_snapshot(&session_id).await.unwrap();

    assert_eq!(
        snapshot.session.runtime_session_id.as_deref(),
        Some("thread-1")
    );
    assert!(
        snapshot
            .events
            .iter()
            .any(|event| event.event_type == "assistant.message"
                && event.payload_json.contains("second-reply"))
    );
    assert_eq!(recorded.lock().unwrap().len(), 2);
}
