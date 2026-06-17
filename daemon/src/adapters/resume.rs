use std::{
    collections::HashMap,
    io::ErrorKind,
    path::{Path, PathBuf},
};

use serde::Deserialize;
use serde_json::{json, Value};
use tokio::{
    fs,
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::Child,
};

use crate::{
    adapters::process::{codex_managed_launch, LaunchCommand},
    session::model::ResumeCandidate,
};

pub async fn list_codex_resume_candidates(
    workspace_path: &str,
    process_spawner: &(dyn Fn(LaunchCommand) -> anyhow::Result<Child> + Send + Sync),
) -> anyhow::Result<Vec<ResumeCandidate>> {
    let mut child = process_spawner(codex_managed_launch())?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| anyhow::anyhow!("codex resume listing missing stdin"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| anyhow::anyhow!("codex resume listing missing stdout"))?;
    let mut lines = BufReader::new(stdout).lines();

    stdin
        .write_all(encode_json_line(build_initialize_request("agent-dock-initialize-1")).as_bytes())
        .await?;
    stdin.flush().await?;
    read_response(&mut lines, "agent-dock-initialize-1").await?;

    stdin
        .write_all(
            encode_json_line(build_thread_list_request(
                "agent-dock-thread-list-2",
                workspace_path,
            ))
            .as_bytes(),
        )
        .await?;
    stdin.flush().await?;

    let response = read_response(&mut lines, "agent-dock-thread-list-2").await?;
    let _ = child.start_kill();
    let _ = child.wait().await;

    let data = response
        .get("data")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    Ok(data
        .into_iter()
        .filter_map(|thread| {
            let runtime_session_id = thread.get("id")?.as_str()?.to_string();
            let title = thread
                .get("name")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| {
                    thread
                        .get("preview")
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|value| !value.is_empty())
                        .map(str::to_owned)
                });
            let updated_at = thread
                .get("updatedAt")
                .and_then(Value::as_i64)
                .map(|value| value.to_string());
            let status = thread
                .get("status")
                .and_then(|status| status.get("type"))
                .and_then(Value::as_str)
                .map(str::to_owned);

            Some(ResumeCandidate {
                runtime_session_id,
                title,
                agent_kind: "codex".into(),
                workspace_path: workspace_path.to_string(),
                updated_at,
                status,
            })
        })
        .collect())
}

pub async fn list_claude_resume_candidates(
    workspace_path: &str,
    projects_root: Option<&Path>,
) -> anyhow::Result<Vec<ResumeCandidate>> {
    let projects_root = projects_root
        .map(Path::to_path_buf)
        .map(Ok)
        .unwrap_or_else(claude_projects_root)?;
    let mut candidates = HashMap::<String, ResumeCandidate>::new();
    let mut directories = vec![projects_root];

    while let Some(directory) = directories.pop() {
        let mut entries = match fs::read_dir(&directory).await {
            Ok(entries) => entries,
            Err(error) if error.kind() == ErrorKind::NotFound => continue,
            Err(error) => return Err(error.into()),
        };

        while let Some(entry) = entries.next_entry().await? {
            let path = entry.path();
            let file_type = entry.file_type().await?;
            if file_type.is_dir() {
                directories.push(path);
                continue;
            }
            if path.extension().and_then(|value| value.to_str()) != Some("jsonl") {
                continue;
            }

            let Some(candidate) = parse_claude_session_file(&path, workspace_path).await? else {
                continue;
            };
            match candidates.get(&candidate.runtime_session_id) {
                Some(existing)
                    if existing.updated_at.as_deref().unwrap_or_default()
                        >= candidate.updated_at.as_deref().unwrap_or_default() => {}
                _ => {
                    candidates.insert(candidate.runtime_session_id.clone(), candidate);
                }
            }
        }
    }

    let mut values = candidates.into_values().collect::<Vec<_>>();
    values.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
    Ok(values)
}

fn claude_projects_root() -> anyhow::Result<PathBuf> {
    let home = std::env::var("HOME").map_err(|_| anyhow::anyhow!("HOME is not set"))?;
    Ok(Path::new(&home).join(".claude").join("projects"))
}

async fn parse_claude_session_file(
    path: &Path,
    workspace_path: &str,
) -> anyhow::Result<Option<ResumeCandidate>> {
    let content = match fs::read_to_string(path).await {
        Ok(value) => value,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };

    let mut runtime_session_id = None;
    let mut title = None;
    let mut updated_at = None;

    for line in content.lines() {
        let Ok(entry) = serde_json::from_str::<ClaudeSessionEntry>(line) else {
            continue;
        };
        if entry.cwd.as_deref() != Some(workspace_path) {
            continue;
        }

        if runtime_session_id.is_none() {
            runtime_session_id = entry.session_id.clone();
        }
        updated_at = entry.timestamp.clone().or(updated_at);

        if title.is_none() {
            title = entry.first_user_text();
        }
    }

    let Some(runtime_session_id) = runtime_session_id else {
        return Ok(None);
    };

    Ok(Some(ResumeCandidate {
        runtime_session_id,
        title,
        agent_kind: "claude".into(),
        workspace_path: workspace_path.to_string(),
        updated_at,
        status: None,
    }))
}

async fn read_response(
    lines: &mut tokio::io::Lines<BufReader<tokio::process::ChildStdout>>,
    expected_id: &str,
) -> anyhow::Result<Value> {
    while let Some(line) = lines.next_line().await? {
        let value: Value = serde_json::from_str(&line)?;
        if value.get("id").and_then(Value::as_str) != Some(expected_id) {
            continue;
        }
        if let Some(message) = value
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(Value::as_str)
        {
            anyhow::bail!("{message}");
        }
        return Ok(value.get("result").cloned().unwrap_or_else(|| json!({})));
    }

    anyhow::bail!("missing response for {expected_id}")
}

fn build_initialize_request(request_id: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "initialize",
        "params": {
            "clientInfo": {
                "name": "agent-dock",
                "version": "0.1.0"
            },
            "capabilities": {
                "notifications": {
                    "suppress": []
                }
            }
        }
    })
}

fn build_thread_list_request(request_id: &str, workspace_path: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "thread/list",
        "params": {
            "cwd": workspace_path,
            "sortKey": "updated_at",
            "sortDirection": "desc",
            "limit": 20
        }
    })
}

fn encode_json_line(value: Value) -> String {
    value.to_string() + "\n"
}

#[derive(Deserialize)]
struct ClaudeSessionEntry {
    #[serde(rename = "sessionId")]
    session_id: Option<String>,
    timestamp: Option<String>,
    cwd: Option<String>,
    #[serde(default)]
    message: Option<ClaudeSessionMessage>,
}

#[derive(Deserialize, Default)]
struct ClaudeSessionMessage {
    #[serde(default)]
    role: Option<String>,
    #[serde(default)]
    content: ClaudeMessageContent,
}

#[derive(Deserialize, Default)]
#[serde(untagged)]
enum ClaudeMessageContent {
    #[default]
    None,
    Text(String),
    Blocks(Vec<ClaudeMessageContentBlock>),
}

#[derive(Deserialize)]
struct ClaudeMessageContentBlock {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    text: Option<String>,
}

impl ClaudeSessionEntry {
    fn first_user_text(&self) -> Option<String> {
        if self.message.as_ref()?.role.as_deref() != Some("user") {
            return None;
        }

        match self.message.as_ref()?.content {
            ClaudeMessageContent::Text(ref value) => {
                let trimmed = value.trim();
                (!trimmed.is_empty()).then(|| trimmed.to_string())
            }
            ClaudeMessageContent::Blocks(ref blocks) => blocks.iter().find_map(|block| {
                if block.kind != "text" {
                    return None;
                }
                let text = block.text.as_deref()?.trim();
                (!text.is_empty()).then(|| text.to_string())
            }),
            ClaudeMessageContent::None => None,
        }
    }
}
