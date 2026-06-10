use std::{sync::Arc, time::Duration};

use agent_workspace_daemon::{
    adapters::process::{spawn_command, LaunchCommand},
    session::{service::SessionService, store::SqliteSessionStore},
};

#[tokio::test]
async fn managed_claude_session_appends_parsed_events_from_process_output() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let spawner = Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "printf '%s\n%s\n' '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"thinking\",\"thinking\":\"plan first\"}]}}' '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}'".into(),
            ],
        })
    });

    let service = SessionService::new_with_spawner(store, spawner);
    let session_id = service
        .create_managed_session("workspace".into(), "repo".into(), "claude".into())
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
}
