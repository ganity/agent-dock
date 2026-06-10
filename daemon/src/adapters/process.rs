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
