use std::process::Stdio;

use tokio::process::{Child, Command};

#[derive(Clone)]
pub struct LaunchCommand {
    pub program: String,
    pub args: Vec<String>,
}

pub fn claude_managed_launch() -> LaunchCommand {
    LaunchCommand {
        program: "claude".into(),
        args: vec![
            "--print".into(),
            "--verbose".into(),
            "--output-format".into(),
            "stream-json".into(),
            "--input-format".into(),
            "stream-json".into(),
        ],
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
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    Ok(child.spawn()?)
}
