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
            None,
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
async fn managed_codex_session_persists_runtime_session_id_after_thread_start() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let spawner = Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _thread; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-start-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 sleep 1".into(),
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
    assert_eq!(
        snapshot.session.runtime_session_id.as_deref(),
        Some("thread-1")
    );
}

#[tokio::test]
async fn managed_codex_session_marks_failed_after_system_error_and_turn_failure() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let spawner = Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _thread; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-start-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"thread/status/changed\",\"params\":{\"status\":{\"type\":\"systemError\"},\"threadId\":\"thread-1\"}}'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"turn/completed\",\"params\":{\"turnId\":\"turn-1\",\"threadId\":\"thread-1\",\"status\":{\"type\":\"failed\",\"message\":\"compact exploded\"}}}'".into(),
            ],
        })
    });

    let service = SessionService::new_with_spawner(store, spawner);
    let session_id = service
        .create_managed_session("workspace".into(), "repo".into(), "codex".into(), None)
        .await
        .unwrap();

    service
        .send_user_message(&session_id, "trigger failure".into())
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(100)).await;

    let snapshot = service.load_snapshot(&session_id).await.unwrap();
    assert_eq!(snapshot.session.status, "failed");
    assert!(snapshot.events.iter().any(|event| {
        event.event_type == "session.status.changed"
            && event.payload_json.contains("compact exploded")
    }));
}

#[tokio::test]
async fn managed_codex_session_keeps_running_status_during_non_terminal_system_error() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let spawner = Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _thread; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-start-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"thread/status/changed\",\"params\":{\"status\":{\"type\":\"systemError\"},\"threadId\":\"thread-1\"}}'; \
                 sleep 0.2; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"still alive\",\"itemId\":\"i1\",\"threadId\":\"thread-1\",\"turnId\":\"turn-1\"}}'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"turn/completed\",\"params\":{\"turnId\":\"turn-1\",\"threadId\":\"thread-1\",\"status\":{\"type\":\"completed\"}}}'".into(),
            ],
        })
    });

    let service = SessionService::new_with_spawner(store, spawner);
    let session_id = service
        .create_managed_session("workspace".into(), "repo".into(), "codex".into(), None)
        .await
        .unwrap();

    service
        .send_user_message(&session_id, "hello".into())
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(100)).await;

    let during_error = service.load_snapshot(&session_id).await.unwrap();
    assert_eq!(during_error.session.status, "running");
    assert!(during_error.events.iter().any(|event| {
        event.event_type == "session.status.changed" && event.payload_json.contains("systemError")
    }));

    tokio::time::sleep(Duration::from_millis(200)).await;

    let final_snapshot = service.load_snapshot(&session_id).await.unwrap();
    assert_eq!(final_snapshot.session.status, "suspended");
    assert!(final_snapshot.events.iter().any(|event| {
        event.event_type == "assistant.message" && event.payload_json.contains("still alive")
    }));
}

#[tokio::test]
async fn managed_codex_session_marks_recoverable_runtime_health_after_error_notification() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let spawner = Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _thread; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-start-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"error\",\"params\":{\"message\":\"temporary reconnect\",\"willRetry\":true,\"threadId\":\"thread-1\"}}'; \
                 sleep 1".into(),
            ],
        })
    });

    let service = SessionService::new_with_spawner(store, spawner);
    let session_id = service
        .create_managed_session("workspace".into(), "repo".into(), "codex".into(), None)
        .await
        .unwrap();

    service
        .send_user_message(&session_id, "hello".into())
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(100)).await;

    let during_error = service.load_snapshot(&session_id).await.unwrap();
    assert_eq!(during_error.session.status, "running");
    assert_eq!(during_error.session.runtime_health, "recoverable_error");
    assert_eq!(
        during_error.session.runtime_error_kind.as_deref(),
        Some("transport")
    );
    assert_eq!(
        during_error.session.runtime_error_message.as_deref(),
        Some("temporary reconnect")
    );
}

#[tokio::test]
async fn managed_codex_session_marks_offline_runtime_health_after_shutdown() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let spawner = Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _thread; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-start-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"turn/completed\",\"params\":{\"turnId\":\"turn-1\",\"threadId\":\"thread-1\",\"status\":{\"type\":\"completed\"}}}'; \
                 sleep 0.1; \
                 exit 0".into(),
            ],
        })
    });

    let service = SessionService::new_with_spawner(store, spawner);
    let session_id = service
        .create_managed_session("workspace".into(), "repo".into(), "codex".into(), None)
        .await
        .unwrap();

    service
        .send_user_message(&session_id, "hello".into())
        .await
        .unwrap();

    let final_snapshot = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            tokio::time::sleep(Duration::from_millis(50)).await;
            let snapshot = service.load_snapshot(&session_id).await.unwrap();
            if snapshot.session.runtime_health == "offline" {
                break snapshot;
            }
        }
    })
    .await
    .expect("runtime health should become offline after process exit");
    assert_eq!(final_snapshot.session.status, "suspended");
    assert_eq!(final_snapshot.session.runtime_health, "offline");
    assert_eq!(final_snapshot.session.runtime_error_message, None);
}

#[tokio::test]
async fn managed_codex_session_sends_compact_slash_command_as_thread_compact_request() {
    let dir = tempdir().unwrap();
    let captured_path = dir.path().join("compact-request.jsonl");
    let captured_path_for_spawner = captured_path.clone();
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let spawner = Arc::new(move |_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _thread; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-start-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 IFS= read -r command_request; printf '%s\n' \"$command_request\" > \"$1\"; \
                 command_id=$(printf '%s' \"$command_request\" | sed -n 's/.*\"id\":\"\\([^\"]*\\)\".*/\\1/p'); \
                 printf '{\"jsonrpc\":\"2.0\",\"id\":\"%s\",\"result\":{}}\n' \"$command_id\"".into(),
                "agent-dock-test".into(),
                captured_path_for_spawner.to_string_lossy().into_owned(),
            ],
        })
    });

    let service = SessionService::new_with_spawner(store, spawner);
    let session_id = service
        .create_managed_session("workspace".into(), "repo".into(), "codex".into(), None)
        .await
        .unwrap();

    service
        .send_user_message(&session_id, "/compact".into())
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(100)).await;

    let captured = tokio::fs::read_to_string(captured_path).await.unwrap();
    assert!(captured.contains(r#""method":"thread/compact/start""#));
    assert!(captured.contains(r#""threadId":"thread-1""#));
    assert!(!captured.contains(r#""method":"turn/start""#));

    let snapshot = service.load_snapshot(&session_id).await.unwrap();
    assert!(
        snapshot
            .events
            .iter()
            .any(|event| event.event_type == "assistant.message"
                && event.payload_json.contains("Compaction started"))
    );
}

#[tokio::test]
async fn managed_codex_session_marks_command_errors_as_recoverable_runtime_health() {
    let dir = tempdir().unwrap();
    let captured_path = dir.path().join("compact-error-request.jsonl");
    let captured_path_for_spawner = captured_path.clone();
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let spawner = Arc::new(move |_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _thread; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-start-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 IFS= read -r command_request; printf '%s\n' \"$command_request\" > \"$1\"; \
                 command_id=$(printf '%s' \"$command_request\" | sed -n 's/.*\"id\":\"\\([^\"]*\\)\".*/\\1/p'); \
                 printf '{\"jsonrpc\":\"2.0\",\"id\":\"%s\",\"error\":{\"code\":-32000,\"message\":\"compact service returned 502\"}}\n' \"$command_id\"; \
                 sleep 1".into(),
                "agent-dock-test".into(),
                captured_path_for_spawner.to_string_lossy().into_owned(),
            ],
        })
    });

    let service = SessionService::new_with_spawner(store, spawner);
    let session_id = service
        .create_managed_session("workspace".into(), "repo".into(), "codex".into(), None)
        .await
        .unwrap();

    service
        .send_user_message(&session_id, "/compact".into())
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(100)).await;

    let captured = tokio::fs::read_to_string(captured_path).await.unwrap();
    assert!(captured.contains(r#""method":"thread/compact/start""#));

    let snapshot = service.load_snapshot(&session_id).await.unwrap();
    assert_eq!(snapshot.session.status, "running");
    assert_eq!(snapshot.session.runtime_health, "recoverable_error");
    assert_eq!(
        snapshot.session.runtime_error_kind.as_deref(),
        Some("provider")
    );
    assert_eq!(
        snapshot.session.runtime_error_message.as_deref(),
        Some("compact service returned 502")
    );
    assert!(
        snapshot
            .events
            .iter()
            .any(|event| event.event_type == "assistant.message"
                && event.payload_json.contains("Command failed")
                && event.payload_json.contains("compact service returned 502"))
    );
}

#[tokio::test]
async fn managed_codex_session_sends_goal_slash_command_as_thread_goal_set_request() {
    let dir = tempdir().unwrap();
    let captured_path = dir.path().join("goal-request.jsonl");
    let captured_path_for_spawner = captured_path.clone();
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let spawner = Arc::new(move |_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _thread; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-start-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 IFS= read -r command_request; printf '%s\n' \"$command_request\" > \"$1\"; \
                 command_id=$(printf '%s' \"$command_request\" | sed -n 's/.*\"id\":\"\\([^\"]*\\)\".*/\\1/p'); \
                 printf '{\"jsonrpc\":\"2.0\",\"id\":\"%s\",\"result\":{\"goal\":{\"threadId\":\"thread-1\",\"objective\":\"Finish slash command support\",\"status\":\"active\",\"tokenBudget\":null,\"tokensUsed\":0,\"timeUsedSeconds\":0,\"createdAt\":1,\"updatedAt\":2}}}\n' \"$command_id\"".into(),
                "agent-dock-test".into(),
                captured_path_for_spawner.to_string_lossy().into_owned(),
            ],
        })
    });

    let service = SessionService::new_with_spawner(store, spawner);
    let session_id = service
        .create_managed_session("workspace".into(), "repo".into(), "codex".into(), None)
        .await
        .unwrap();

    service
        .send_user_message(&session_id, "/goal Finish slash command support".into())
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(100)).await;

    let captured = tokio::fs::read_to_string(captured_path).await.unwrap();
    assert!(captured.contains(r#""method":"thread/goal/set""#));
    assert!(captured.contains(r#""objective":"Finish slash command support""#));
    assert!(!captured.contains(r#""method":"turn/start""#));

    let snapshot = service.load_snapshot(&session_id).await.unwrap();
    assert!(
        snapshot
            .events
            .iter()
            .any(|event| event.event_type == "assistant.message"
                && event.payload_json.contains("Goal set")
                && event.payload_json.contains("Finish slash command support"))
    );
}

#[tokio::test]
async fn managed_codex_session_sends_new_slash_command_as_fresh_thread_start() {
    let dir = tempdir().unwrap();
    let captured_path = dir.path().join("new-request.jsonl");
    let captured_path_for_spawner = captured_path.clone();
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let spawner = Arc::new(move |_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _thread; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-start-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 IFS= read -r command_request; printf '%s\n' \"$command_request\" > \"$1\"; \
                 command_id=$(printf '%s' \"$command_request\" | sed -n 's/.*\"id\":\"\\([^\"]*\\)\".*/\\1/p'); \
                 printf '{\"jsonrpc\":\"2.0\",\"id\":\"%s\",\"result\":{\"thread\":{\"id\":\"thread-2\"}}}\n' \"$command_id\"".into(),
                "agent-dock-test".into(),
                captured_path_for_spawner.to_string_lossy().into_owned(),
            ],
        })
    });

    let service = SessionService::new_with_spawner(store, spawner);
    let session_id = service
        .create_managed_session("workspace".into(), "repo".into(), "codex".into(), None)
        .await
        .unwrap();

    service
        .send_user_message(&session_id, "/new".into())
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(100)).await;

    let captured = tokio::fs::read_to_string(captured_path).await.unwrap();
    assert!(captured.contains(r#""method":"thread/start""#));
    assert!(captured.contains(r#""cwd":"repo""#));
    assert!(!captured.contains(r#""method":"turn/start""#));
    assert!(!captured.contains(r#""threadId":"thread-1""#));

    let snapshot = service.load_snapshot(&session_id).await.unwrap();
    assert_eq!(
        snapshot.session.runtime_session_id.as_deref(),
        Some("thread-2")
    );
    assert!(
        snapshot
            .events
            .iter()
            .any(|event| event.event_type == "assistant.message"
                && event.payload_json.contains("Started a new agent session"))
    );
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

#[tokio::test]
async fn managed_codex_session_can_resume_runtime_without_sending_message() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let spawner = Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _resume; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-resume-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"thread/status/changed\",\"params\":{\"status\":{\"type\":\"active\"},\"threadId\":\"thread-1\"}}'; \
                 sleep 1".into(),
            ],
        })
    });

    let service = SessionService::new_with_spawner(store, spawner);
    let session_id = service
        .attach_existing_session(
            "workspace".into(),
            "repo".into(),
            "codex".into(),
            "thread-1".into(),
        )
        .await
        .unwrap();

    service.resume_session(&session_id).await.unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;

    let snapshot = service.load_snapshot(&session_id).await.unwrap();
    assert_eq!(snapshot.session.status, "running");
    assert!(snapshot.events.iter().any(|event| {
        event.event_type == "session.status.changed" && event.payload_json.contains("active")
    }));
    assert!(
        !snapshot
            .events
            .iter()
            .any(|event| event.event_type == "user.message")
    );
}

#[tokio::test]
async fn managed_codex_session_drains_persisted_pending_messages_after_resume() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("agent-dock.sqlite3");
    let captured_path = dir.path().join("pending-turn.jsonl");
    let captured_path_for_spawner = captured_path.clone();
    let spawner = Arc::new(move |_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _resume; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-resume-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 IFS= read -r turn_request; printf '%s\n' \"$turn_request\" > \"$1\"; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"drained reply\",\"threadId\":\"thread-1\",\"turnId\":\"turn-1\"}}'; \
                 sleep 1".into(),
                "agent-dock-test".into(),
                captured_path_for_spawner.to_string_lossy().into_owned(),
            ],
        })
    });

    let seed_store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let session_id = seed_store
        .create_session(
            "usr_workspace".into(),
            "workspace".into(),
            "repo".into(),
            "attached".into(),
            "codex".into(),
            None,
        )
        .await
        .unwrap();
    seed_store
        .update_runtime_session_id(&session_id, "thread-1")
        .await
        .unwrap();
    seed_store
        .append_user_message_and_enqueue_pending(
            &session_id,
            None,
            "queued while offline".into(),
            &[],
        )
        .await
        .unwrap();
    drop(seed_store);

    let store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let service = SessionService::new_with_spawner(store, spawner);
    service.resume_session(&session_id).await.unwrap();

    tokio::time::sleep(Duration::from_millis(150)).await;

    let captured = tokio::fs::read_to_string(captured_path).await.unwrap();
    assert!(captured.contains(r#""method":"turn/start""#));
    assert!(captured.contains("queued while offline"));

    let snapshot = service.load_snapshot(&session_id).await.unwrap();
    assert!(
        snapshot
            .events
            .iter()
            .any(|event| event.event_type == "assistant.message"
                && event.payload_json.contains("drained reply"))
    );

    let verify_store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    assert!(
        verify_store
            .pending_user_messages(&session_id)
            .await
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn managed_codex_session_sends_only_one_pending_message_until_turn_completes() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("agent-dock.sqlite3");
    let first_path = dir.path().join("first-turn.jsonl");
    let second_path = dir.path().join("second-turn.jsonl");
    let early_second_path = dir.path().join("early-second.jsonl");
    let marker_path = dir.path().join("before-completion.marker");
    let first_path_for_spawner = first_path.clone();
    let second_path_for_spawner = second_path.clone();
    let early_second_path_for_spawner = early_second_path.clone();
    let marker_path_for_spawner = marker_path.clone();
    let spawner = Arc::new(move |_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "bash".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _resume; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-resume-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 IFS= read -r first_turn; printf '%s\n' \"$first_turn\" > \"$1\"; \
                 sleep 0.2; \
                 if IFS= read -r -t 0.1 early_second; then printf '%s\n' \"$early_second\" > \"$3\"; fi; \
                 touch \"$4\"; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"turn/completed\",\"params\":{\"turnId\":\"turn-1\",\"threadId\":\"thread-1\",\"status\":{\"type\":\"completed\"}}}'; \
                 IFS= read -r second_turn; printf '%s\n' \"$second_turn\" > \"$2\"; \
                 sleep 1".into(),
                "agent-dock-test".into(),
                first_path_for_spawner.to_string_lossy().into_owned(),
                second_path_for_spawner.to_string_lossy().into_owned(),
                early_second_path_for_spawner.to_string_lossy().into_owned(),
                marker_path_for_spawner.to_string_lossy().into_owned(),
            ],
        })
    });

    let seed_store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let session_id = seed_store
        .create_session(
            "usr_workspace".into(),
            "workspace".into(),
            "repo".into(),
            "attached".into(),
            "codex".into(),
            None,
        )
        .await
        .unwrap();
    seed_store
        .update_runtime_session_id(&session_id, "thread-1")
        .await
        .unwrap();
    seed_store
        .append_user_message_and_enqueue_pending(&session_id, None, "first queued".into(), &[])
        .await
        .unwrap();
    seed_store
        .append_user_message_and_enqueue_pending(&session_id, None, "second queued".into(), &[])
        .await
        .unwrap();
    drop(seed_store);

    let store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let service = SessionService::new_with_spawner(store, spawner);
    service.resume_session(&session_id).await.unwrap();

    tokio::time::timeout(Duration::from_secs(2), async {
        while !marker_path.exists() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("runtime should reach the pre-completion marker");

    let first = tokio::fs::read_to_string(&first_path).await.unwrap();
    assert!(first.contains("first queued"));
    assert!(
        !early_second_path.exists(),
        "second pending message should not be sent before first turn completes"
    );

    tokio::time::timeout(Duration::from_secs(2), async {
        while !second_path.exists() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("second pending message should be sent after turn completion");

    let second = tokio::fs::read_to_string(&second_path).await.unwrap();
    assert!(second.contains("second queued"));
}

#[tokio::test]
async fn managed_codex_session_rebinds_turn_after_resume_replay_and_drains_pending_messages() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("agent-dock.sqlite3");
    let first_path = dir.path().join("first-turn.jsonl");
    let second_path = dir.path().join("second-turn.jsonl");
    let first_path_for_spawner = first_path.clone();
    let second_path_for_spawner = second_path.clone();
    let spawner = Arc::new(move |_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "bash".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _resume; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-resume-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 IFS= read -r first_turn; printf '%s\n' \"$first_turn\" > \"$1\"; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"turn/started\",\"params\":{\"threadId\":\"thread-1\",\"turn\":{\"id\":\"turn-stale\"}}}'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"turn/started\",\"params\":{\"threadId\":\"thread-1\",\"turn\":{\"id\":\"turn-current\"}}}'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"turn/completed\",\"params\":{\"turnId\":\"turn-current\",\"threadId\":\"thread-1\",\"status\":{\"type\":\"completed\"}}}'; \
                 IFS= read -r second_turn; printf '%s\n' \"$second_turn\" > \"$2\"; \
                 sleep 1".into(),
                "agent-dock-test".into(),
                first_path_for_spawner.to_string_lossy().into_owned(),
                second_path_for_spawner.to_string_lossy().into_owned(),
            ],
        })
    });

    let seed_store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let session_id = seed_store
        .create_session(
            "usr_workspace".into(),
            "workspace".into(),
            "repo".into(),
            "attached".into(),
            "codex".into(),
            None,
        )
        .await
        .unwrap();
    seed_store
        .update_runtime_session_id(&session_id, "thread-1")
        .await
        .unwrap();
    seed_store
        .append_user_message_and_enqueue_pending(&session_id, None, "first queued".into(), &[])
        .await
        .unwrap();
    seed_store
        .append_user_message_and_enqueue_pending(&session_id, None, "second queued".into(), &[])
        .await
        .unwrap();
    drop(seed_store);

    let store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let service = SessionService::new_with_spawner(store, spawner);
    service.resume_session(&session_id).await.unwrap();

    tokio::time::timeout(Duration::from_secs(2), async {
        while !first_path.exists() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("runtime should receive the first pending message");

    tokio::time::timeout(Duration::from_secs(2), async {
        while !second_path.exists() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("second pending message should drain after the current turn completes");

    let first = tokio::fs::read_to_string(&first_path).await.unwrap();
    let second = tokio::fs::read_to_string(&second_path).await.unwrap();
    assert!(first.contains("first queued"));
    assert!(second.contains("second queued"));
}

#[tokio::test]
async fn managed_codex_session_does_not_ack_in_flight_message_for_foreign_turn_completion() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("agent-dock.sqlite3");
    let captured_path = dir.path().join("turn.jsonl");
    let captured_path_for_spawner = captured_path.clone();
    let spawner = Arc::new(move |_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _resume; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-resume-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 IFS= read -r turn_request; printf '%s\n' \"$turn_request\" > \"$1\"; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"turn/started\",\"params\":{\"threadId\":\"thread-1\",\"turn\":{\"id\":\"turn-1\"}}}'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"turn/completed\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-foreign\",\"status\":{\"type\":\"completed\"}}}'; \
                 sleep 1".into(),
                "agent-dock-test".into(),
                captured_path_for_spawner.to_string_lossy().into_owned(),
            ],
        })
    });

    let seed_store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let session_id = seed_store
        .create_session(
            "usr_workspace".into(),
            "workspace".into(),
            "repo".into(),
            "attached".into(),
            "codex".into(),
            None,
        )
        .await
        .unwrap();
    seed_store
        .update_runtime_session_id(&session_id, "thread-1")
        .await
        .unwrap();
    seed_store
        .append_user_message_and_enqueue_pending(&session_id, None, "stay pending".into(), &[])
        .await
        .unwrap();
    drop(seed_store);

    let store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let service = SessionService::new_with_spawner(store, spawner);
    service.resume_session(&session_id).await.unwrap();

    tokio::time::timeout(Duration::from_secs(2), async {
        while !captured_path.exists() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("runtime should receive the pending message");

    tokio::time::sleep(Duration::from_millis(150)).await;

    let verify_store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let pending = verify_store
        .pending_user_messages(&session_id)
        .await
        .unwrap();
    let in_flight = verify_store
        .in_flight_user_message(&session_id)
        .await
        .unwrap();
    assert!(pending.is_empty());
    assert_eq!(in_flight.unwrap().text, "stay pending");
}

#[tokio::test]
async fn managed_codex_session_retries_in_flight_message_after_runtime_exits_before_completion() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("agent-dock.sqlite3");
    let first_attempt_path = dir.path().join("first-attempt.jsonl");
    let retry_attempt_path = dir.path().join("retry-attempt.jsonl");
    let first_attempt_path_for_spawner = first_attempt_path.clone();
    let retry_attempt_path_for_spawner = retry_attempt_path.clone();
    let launch_count = Arc::new(std::sync::Mutex::new(0usize));
    let launch_count_for_spawner = launch_count.clone();
    let spawner = Arc::new(move |_command: LaunchCommand| {
        let mut launch_count = launch_count_for_spawner.lock().unwrap();
        *launch_count += 1;
        let launch_number = *launch_count;
        drop(launch_count);

        let capture_path = if launch_number == 1 {
            first_attempt_path_for_spawner.clone()
        } else {
            retry_attempt_path_for_spawner.clone()
        };

        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                if launch_number == 1 {
                    "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                     IFS= read -r _resume; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-resume-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                     IFS= read -r turn_request; printf '%s\n' \"$turn_request\" > \"$1\"; \
                     exit 1".into()
                } else {
                    "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                     IFS= read -r _resume; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-resume-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                     IFS= read -r turn_request; printf '%s\n' \"$turn_request\" > \"$1\"; \
                     printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"turn/completed\",\"params\":{\"turnId\":\"turn-1\",\"threadId\":\"thread-1\",\"status\":{\"type\":\"completed\"}}}'; \
                     sleep 1".into()
                },
                "agent-dock-test".into(),
                capture_path.to_string_lossy().into_owned(),
            ],
        })
    });

    let seed_store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let session_id = seed_store
        .create_session(
            "usr_workspace".into(),
            "workspace".into(),
            "repo".into(),
            "attached".into(),
            "codex".into(),
            None,
        )
        .await
        .unwrap();
    seed_store
        .update_runtime_session_id(&session_id, "thread-1")
        .await
        .unwrap();
    seed_store
        .append_user_message_and_enqueue_pending(&session_id, None, "retry me".into(), &[])
        .await
        .unwrap();
    drop(seed_store);

    let store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let service = SessionService::new_with_spawner(store, spawner);
    service.resume_session(&session_id).await.unwrap();

    tokio::time::timeout(Duration::from_secs(2), async {
        while !first_attempt_path.exists() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("first runtime should receive the pending message");

    service.resume_session(&session_id).await.unwrap();

    tokio::time::timeout(Duration::from_secs(2), async {
        while !retry_attempt_path.exists() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("second runtime should retry the uncompleted in-flight message");

    let first_attempt = tokio::fs::read_to_string(&first_attempt_path)
        .await
        .unwrap();
    let retry_attempt = tokio::fs::read_to_string(&retry_attempt_path)
        .await
        .unwrap();
    assert!(first_attempt.contains("retry me"));
    assert!(retry_attempt.contains("retry me"));
}

#[tokio::test]
async fn managed_codex_session_marks_runtime_crash_with_in_flight_message_as_recoverable() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("agent-dock.sqlite3");
    let captured_path = dir.path().join("crashed-turn.jsonl");
    let captured_path_for_spawner = captured_path.clone();
    let spawner = Arc::new(move |_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _resume; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-resume-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 IFS= read -r turn_request; printf '%s\n' \"$turn_request\" > \"$1\"; \
                 exit 1".into(),
                "agent-dock-test".into(),
                captured_path_for_spawner.to_string_lossy().into_owned(),
            ],
        })
    });

    let seed_store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let session_id = seed_store
        .create_session(
            "usr_workspace".into(),
            "workspace".into(),
            "repo".into(),
            "attached".into(),
            "codex".into(),
            None,
        )
        .await
        .unwrap();
    seed_store
        .update_runtime_session_id(&session_id, "thread-1")
        .await
        .unwrap();
    seed_store
        .append_user_message_and_enqueue_pending(
            &session_id,
            None,
            "recover after crash".into(),
            &[],
        )
        .await
        .unwrap();
    drop(seed_store);

    let store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let service = SessionService::new_with_spawner(store, spawner);
    service.resume_session(&session_id).await.unwrap();

    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            tokio::time::sleep(Duration::from_millis(20)).await;
            let snapshot = service.load_snapshot(&session_id).await.unwrap();
            if snapshot.session.runtime_health == "recoverable_error" {
                break;
            }
        }
    })
    .await
    .expect("runtime crash should be classified as recoverable while a message is unacknowledged");

    let snapshot = service.load_snapshot(&session_id).await.unwrap();
    assert_eq!(snapshot.session.runtime_health, "recoverable_error");
    assert_eq!(
        snapshot.session.runtime_error_kind.as_deref(),
        Some("runtime")
    );
    assert!(
        snapshot
            .session
            .runtime_error_message
            .as_deref()
            .unwrap_or_default()
            .contains("exited")
    );
    assert!(snapshot.events.iter().any(|event| {
        event.event_type == "session.error" && event.payload_json.contains("recover after crash")
    }));

    let verify_store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let pending = verify_store
        .pending_user_messages(&session_id)
        .await
        .unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].text, "recover after crash");
    assert!(
        verify_store
            .in_flight_user_message(&session_id)
            .await
            .unwrap()
            .is_none()
    );
}

#[tokio::test]
async fn managed_codex_session_marks_send_failure_as_desynced_and_requeues_message() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("agent-dock.sqlite3");
    let spawner = Arc::new(move |_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _resume; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-resume-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 exec 0<&-; \
                 sleep 1".into(),
            ],
        })
    });

    let seed_store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let session_id = seed_store
        .create_session(
            "usr_workspace".into(),
            "workspace".into(),
            "repo".into(),
            "attached".into(),
            "codex".into(),
            None,
        )
        .await
        .unwrap();
    seed_store
        .update_runtime_session_id(&session_id, "thread-1")
        .await
        .unwrap();
    seed_store
        .append_user_message_and_enqueue_pending(&session_id, None, "retry after desync".into(), &[])
        .await
        .unwrap();
    drop(seed_store);

    let store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let service = SessionService::new_with_spawner(store, spawner);
    service.resume_session(&session_id).await.unwrap();

    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let snapshot = service.load_snapshot(&session_id).await.unwrap();
            if snapshot.session.runtime_health == "desynced" {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("send failure should desync the session");

    let verify_store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let pending = verify_store
        .pending_user_messages(&session_id)
        .await
        .unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].text, "retry after desync");
    assert!(
        verify_store
            .in_flight_user_message(&session_id)
            .await
            .unwrap()
            .is_none()
    );

    let snapshot = service.load_snapshot(&session_id).await.unwrap();
    assert_eq!(snapshot.session.runtime_health, "desynced");
    assert_eq!(
        snapshot.session.runtime_error_kind.as_deref(),
        Some("transport")
    );
}

#[tokio::test]
async fn managed_codex_session_resumes_desynced_session_before_sending_next_message() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("agent-dock.sqlite3");
    let second_attempt_path = dir.path().join("desync-second.jsonl");
    let second_attempt_path_for_spawner = second_attempt_path.clone();
    let launch_count = Arc::new(std::sync::Mutex::new(0usize));
    let launch_count_for_spawner = launch_count.clone();
    let spawner = Arc::new(move |_command: LaunchCommand| {
        let mut launch_count = launch_count_for_spawner.lock().unwrap();
        *launch_count += 1;
        let launch_number = *launch_count;
        drop(launch_count);

        let capture_path = second_attempt_path_for_spawner.clone();

        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                if launch_number == 1 {
                    "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                     IFS= read -r _resume; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-resume-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                     exec 0<&-; \
                     sleep 1".into()
                } else {
                    "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                     IFS= read -r _resume; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-resume-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                     IFS= read -r turn_request; printf '%s\n' \"$turn_request\" > \"$1\"; \
                     printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"turn/completed\",\"params\":{\"turnId\":\"turn-1\",\"threadId\":\"thread-1\",\"status\":{\"type\":\"completed\"}}}'; \
                     sleep 1".into()
                },
                "agent-dock-test".into(),
                capture_path.to_string_lossy().into_owned(),
            ],
        })
    });

    let seed_store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let session_id = seed_store
        .create_session(
            "usr_workspace".into(),
            "workspace".into(),
            "repo".into(),
            "attached".into(),
            "codex".into(),
            None,
        )
        .await
        .unwrap();
    seed_store
        .update_runtime_session_id(&session_id, "thread-1")
        .await
        .unwrap();
    seed_store
        .append_user_message_and_enqueue_pending(&session_id, None, "first message".into(), &[])
        .await
        .unwrap();
    drop(seed_store);

    let store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let service = SessionService::new_with_spawner(store, spawner);
    service.resume_session(&session_id).await.unwrap();

    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let snapshot = service.load_snapshot(&session_id).await.unwrap();
            if snapshot.session.runtime_health == "desynced" {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("first send should desync");

    service
        .send_user_message(&session_id, "second message".into())
        .await
        .unwrap();

    tokio::time::timeout(Duration::from_secs(2), async {
        while !second_attempt_path.exists() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("second runtime should send the next message after resume");

    let second_attempt = tokio::fs::read_to_string(&second_attempt_path)
        .await
        .unwrap();
    assert!(second_attempt.contains("first message") || second_attempt.contains("second message"));

    let snapshot = service.load_snapshot(&session_id).await.unwrap();
    assert_ne!(snapshot.session.runtime_health, "desynced");
}

#[tokio::test]
async fn managed_codex_session_falls_back_to_fresh_start_after_resume_protocol_error() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
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
                     IFS= read -r _resume; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-resume-2\",\"error\":{\"code\":-32602,\"message\":\"unknown thread\"}}'; \
                     IFS= read -r _start; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-start-3\",\"result\":{\"thread\":{\"id\":\"thread-fresh\"}}}'; \
                     IFS= read -r _turn; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"fresh reply\",\"threadId\":\"thread-fresh\",\"turnId\":\"turn-1\"}}'".into(),
                ],
            }),
            _ => unreachable!("test should only spawn one runtime"),
        }
    });

    let service = SessionService::new_with_spawner(store, spawner);
    let session_id = service
        .attach_existing_session(
            "workspace".into(),
            "repo".into(),
            "codex".into(),
            "thread-stale".into(),
        )
        .await
        .unwrap();

    service
        .send_user_message(&session_id, "recover please".into())
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(150)).await;

    let snapshot = service.load_snapshot(&session_id).await.unwrap();
    assert_eq!(
        snapshot.session.runtime_session_id.as_deref(),
        Some("thread-fresh")
    );
    assert!(snapshot.events.iter().any(|event| {
        event.event_type == "assistant.message" && event.payload_json.contains("fresh reply")
    }));
    assert_eq!(recorded.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn managed_codex_session_falls_back_to_fresh_start_after_resume_missing_thread_id() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let spawner = Arc::new(move |_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _resume; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-resume-2\",\"result\":{\"thread\":{}}}'; \
                 IFS= read -r _start; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-start-3\",\"result\":{\"thread\":{\"id\":\"thread-fresh\"}}}'; \
                 IFS= read -r _turn; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"fresh reply\",\"threadId\":\"thread-fresh\",\"turnId\":\"turn-1\"}}'".into(),
            ],
        })
    });

    let service = SessionService::new_with_spawner(store, spawner);
    let session_id = service
        .attach_existing_session(
            "workspace".into(),
            "repo".into(),
            "codex".into(),
            "thread-stale".into(),
        )
        .await
        .unwrap();

    service
        .send_user_message(&session_id, "recover please".into())
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(150)).await;

    let snapshot = service.load_snapshot(&session_id).await.unwrap();
    assert_eq!(
        snapshot.session.runtime_session_id.as_deref(),
        Some("thread-fresh")
    );
    assert!(snapshot.events.iter().any(|event| {
        event.event_type == "assistant.message" && event.payload_json.contains("fresh reply")
    }));
}

#[tokio::test]
async fn managed_codex_session_keeps_consuming_events_after_error_notification() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let spawner = Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _thread; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-start-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"error\",\"params\":{\"message\":\"temporary reconnect\",\"willRetry\":true,\"threadId\":\"thread-1\"}}'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"still alive\",\"itemId\":\"i1\",\"threadId\":\"thread-1\",\"turnId\":\"turn-1\"}}'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"turn/completed\",\"params\":{\"turnId\":\"turn-1\",\"threadId\":\"thread-1\",\"status\":{\"type\":\"completed\"}}}'".into(),
            ],
        })
    });

    let service = SessionService::new_with_spawner(store, spawner);
    let session_id = service
        .create_managed_session("workspace".into(), "repo".into(), "codex".into(), None)
        .await
        .unwrap();

    service
        .send_user_message(&session_id, "hello".into())
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(150)).await;

    let snapshot = service.load_snapshot(&session_id).await.unwrap();
    assert!(snapshot.events.iter().any(|event| {
        event.event_type == "session.error" && event.payload_json.contains("temporary reconnect")
    }));
    assert!(snapshot.events.iter().any(|event| {
        event.event_type == "assistant.message" && event.payload_json.contains("still alive")
    }));
}

#[tokio::test]
async fn managed_codex_session_records_protocol_parse_errors_and_keeps_consuming_events() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let spawner = Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _thread; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-start-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 printf '%s\n' '{bad-json'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"after parse error\",\"itemId\":\"i1\",\"threadId\":\"thread-1\",\"turnId\":\"turn-1\"}}'; \
                 sleep 1".into(),
            ],
        })
    });

    let service = SessionService::new_with_spawner(store, spawner);
    let session_id = service
        .create_managed_session("workspace".into(), "repo".into(), "codex".into(), None)
        .await
        .unwrap();

    service
        .send_user_message(&session_id, "hello".into())
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(150)).await;

    let snapshot = service.load_snapshot(&session_id).await.unwrap();
    assert_eq!(snapshot.session.status, "running");
    assert_eq!(snapshot.session.runtime_health, "recoverable_error");
    assert_eq!(
        snapshot.session.runtime_error_kind.as_deref(),
        Some("protocol")
    );
    assert!(
        snapshot
            .session
            .runtime_error_message
            .as_deref()
            .unwrap_or_default()
            .contains("protocol")
    );
    assert!(snapshot.events.iter().any(|event| {
        event.event_type == "session.error" && event.payload_json.contains("protocol")
    }));
    assert!(snapshot.events.iter().any(|event| {
        event.event_type == "assistant.message" && event.payload_json.contains("after parse error")
    }));
}

#[tokio::test]
async fn managed_codex_session_keeps_consuming_events_after_context_compaction_lifecycle() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let spawner = Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _thread; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-start-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"turn/started\",\"params\":{\"threadId\":\"thread-1\",\"turn\":{\"id\":\"turn-1\"}}}'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"item/started\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"item\":{\"id\":\"compact-1\",\"type\":\"contextCompaction\"}}}'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"thread/status/changed\",\"params\":{\"status\":{\"type\":\"systemError\"},\"threadId\":\"thread-1\"}}'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"item/completed\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"item\":{\"id\":\"compact-1\",\"type\":\"contextCompaction\"}}}'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"after compact\",\"itemId\":\"i1\",\"threadId\":\"thread-1\",\"turnId\":\"turn-1\"}}'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"turn/completed\",\"params\":{\"turnId\":\"turn-1\",\"threadId\":\"thread-1\",\"status\":{\"type\":\"completed\"}}}'".into(),
            ],
        })
    });

    let service = SessionService::new_with_spawner(store, spawner);
    let session_id = service
        .create_managed_session("workspace".into(), "repo".into(), "codex".into(), None)
        .await
        .unwrap();

    service
        .send_user_message(&session_id, "hello".into())
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(150)).await;

    let snapshot = service.load_snapshot(&session_id).await.unwrap();
    assert!(snapshot.events.iter().any(|event| {
        event.event_type == "tool.call.started" && event.payload_json.contains("contextCompaction")
    }));
    assert!(snapshot.events.iter().any(|event| {
        event.event_type == "tool.call.completed"
            && event.payload_json.contains("contextCompaction")
    }));
    assert!(snapshot.events.iter().any(|event| {
        event.event_type == "assistant.message" && event.payload_json.contains("after compact")
    }));
}
