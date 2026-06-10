#[derive(Clone)]
pub struct WorkspaceRoot {
    pub id: String,
    pub label: String,
    pub path: String,
}

#[derive(Clone)]
pub struct AppConfig {
    pub listen: String,
    pub pin: String,
    pub roots: Vec<WorkspaceRoot>,
}

impl AppConfig {
    pub fn for_tests() -> Self {
        Self {
            listen: "127.0.0.1:4123".into(),
            pin: "1234".into(),
            roots: vec![WorkspaceRoot {
                id: "workspace".into(),
                label: "Workspace".into(),
                path: "/tmp/workspace".into(),
            }],
        }
    }
}
