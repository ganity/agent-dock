use std::{
    env, fs,
    path::{Path, PathBuf},
};

use anyhow::{Context, anyhow};
use serde::Deserialize;

#[derive(Clone, Debug, Deserialize)]
pub struct WorkspaceRoot {
    pub id: String,
    pub label: String,
    pub path: String,
}

#[derive(Clone, Debug, Deserialize)]
pub struct VoiceInputConfig {
    pub websocket_url: String,
    pub app_id: String,
    pub access_token: String,
    pub resource_id: String,
}

#[derive(Clone, Debug, Deserialize)]
pub struct AppConfig {
    pub listen: String,
    pub pin: String,
    pub database_path: String,
    pub roots: Vec<WorkspaceRoot>,
    pub voice_input: Option<VoiceInputConfig>,
}

impl AppConfig {
    pub fn load() -> anyhow::Result<Self> {
        let mut config = if let Ok(path) = env::var("AGENT_DOCK_CONFIG") {
            Self::from_path(Path::new(&path))
                .with_context(|| format!("failed to load config from AGENT_DOCK_CONFIG={path}"))?
        } else {
            Self::load_from_candidates(&[
                PathBuf::from("./daemon.local.toml"),
                PathBuf::from("./daemon.toml"),
                PathBuf::from("./daemon.example.toml"),
            ])?
        };

        if let Some(voice_input) = voice_input_from_env() {
            config.voice_input = Some(voice_input);
        }

        Ok(config)
    }

    pub fn load_from_candidates<P: AsRef<Path>>(candidates: &[P]) -> anyhow::Result<Self> {
        let path = candidates
            .iter()
            .map(AsRef::as_ref)
            .find(|candidate| candidate.exists())
            .ok_or_else(|| anyhow!("no daemon config file found"))?;
        Self::from_path(path)
    }

    pub fn from_path(path: &Path) -> anyhow::Result<Self> {
        let contents = fs::read_to_string(path)
            .with_context(|| format!("failed to read daemon config at {}", path.display()))?;
        toml::from_str(&contents)
            .with_context(|| format!("failed to parse daemon config at {}", path.display()))
    }

    pub fn for_tests() -> Self {
        Self {
            listen: "127.0.0.1:4123".into(),
            pin: "1234".into(),
            database_path: "./daemon-data/agent-dock.sqlite3".into(),
            roots: vec![WorkspaceRoot {
                id: "workspace".into(),
                label: "Workspace".into(),
                path: "/tmp/workspace".into(),
            }],
            voice_input: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use tempfile::tempdir;

    use super::AppConfig;

    #[test]
    fn load_from_candidates_prefers_local_config_and_parses_voice_input() {
        let temp = tempdir().unwrap();
        let example_path = temp.path().join("daemon.example.toml");
        let local_path = temp.path().join("daemon.local.toml");

        std::fs::write(
            &example_path,
            r#"
listen = "127.0.0.1:9999"
pin = "1111"
database_path = "./daemon-data/example.sqlite3"

[[roots]]
id = "workspace"
label = "Example"
path = "/tmp/example"
"#,
        )
        .unwrap();

        std::fs::write(
            &local_path,
            r#"
listen = "127.0.0.1:5123"
pin = "2468"
database_path = "./daemon-data/local.sqlite3"

[voice_input]
websocket_url = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
app_id = "app-id-local"
access_token = "token-local"
resource_id = "volc.bigasr.sauc.duration"

[[roots]]
id = "workspace"
label = "Workspace"
path = "/Users/demo/workspace"
"#,
        )
        .unwrap();

        let config = AppConfig::load_from_candidates(&[
            PathBuf::from(temp.path().join("missing.toml")),
            local_path,
            example_path,
        ])
        .unwrap();

        assert_eq!(config.listen, "127.0.0.1:5123");
        assert_eq!(config.pin, "2468");
        assert_eq!(config.database_path, "./daemon-data/local.sqlite3");
        assert_eq!(config.roots.len(), 1);
        assert_eq!(config.roots[0].path, "/Users/demo/workspace");
        let voice_input = config.voice_input.expect("voice input should load from local config");
        assert_eq!(
            voice_input.websocket_url,
            "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
        );
        assert_eq!(voice_input.app_id, "app-id-local");
        assert_eq!(voice_input.access_token, "token-local");
        assert_eq!(voice_input.resource_id, "volc.bigasr.sauc.duration");
    }

    #[test]
    fn load_from_candidates_falls_back_to_example_config() {
        let temp = tempdir().unwrap();
        let example_path = temp.path().join("daemon.example.toml");

        std::fs::write(
            &example_path,
            r#"
listen = "127.0.0.1:4123"
pin = "1234"
database_path = "./daemon-data/agent-dock.sqlite3"

[[roots]]
id = "workspace"
label = "Workspace"
path = "/tmp/workspace"
"#,
        )
        .unwrap();

        let config = AppConfig::load_from_candidates(&[
            temp.path().join("daemon.local.toml"),
            example_path,
        ])
        .unwrap();

        assert_eq!(config.listen, "127.0.0.1:4123");
        assert_eq!(config.pin, "1234");
        assert!(config.voice_input.is_none());
    }
}

fn voice_input_from_env() -> Option<VoiceInputConfig> {
    let app_id = env::var("AGENT_DOCK_ASR_APP_ID").ok()?;
    let access_token = env::var("AGENT_DOCK_ASR_ACCESS_TOKEN").ok()?;
    let app_id = app_id.trim();
    let access_token = access_token.trim();

    if app_id.is_empty() || access_token.is_empty() {
        return None;
    }

    Some(VoiceInputConfig {
        websocket_url: env::var("AGENT_DOCK_ASR_URL")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async".into()),
        app_id: app_id.to_string(),
        access_token: access_token.to_string(),
        resource_id: env::var("AGENT_DOCK_ASR_RESOURCE_ID")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| "volc.bigasr.sauc.duration".into()),
    })
}
