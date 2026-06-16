use std::process::Stdio;

use tokio::process::{Child, Command};

#[derive(Clone)]
pub struct LaunchCommand {
    pub program: String,
    pub args: Vec<String>,
}

pub fn claude_managed_launch() -> LaunchCommand {
    claude_turn_launch("", None)
}

pub fn claude_turn_launch(message: &str, resume_session_id: Option<&str>) -> LaunchCommand {
    let mut args = vec![
        "--print".into(),
        "--bare".into(),
        "--verbose".into(),
        "--output-format".into(),
        "stream-json".into(),
        "--include-partial-messages".into(),
    ];

    if let Some(session_id) = resume_session_id {
        args.push("--resume".into());
        args.push(session_id.to_string());
    }

    if !message.is_empty() {
        args.push(message.to_string());
    }

    LaunchCommand {
        program: "claude".into(),
        args,
    }
}

pub fn codex_managed_launch() -> LaunchCommand {
    LaunchCommand {
        program: "codex".into(),
        args: vec!["app-server".into(), "--stdio".into()],
    }
}

pub fn spawn_command(command: LaunchCommand) -> anyhow::Result<Child> {
    let mut child = Command::new(&command.program);
    child
        .args(command.args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    Ok(child.spawn()?)
}
