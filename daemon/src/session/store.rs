use sqlx::{Row, SqlitePool};
use uuid::Uuid;

use crate::session::model::{SessionRecord, SessionSnapshot, StoredEvent};

pub struct SqliteSessionStore {
    pool: SqlitePool,
}

impl SqliteSessionStore {
    pub async fn in_memory() -> anyhow::Result<Self> {
        let pool = SqlitePool::connect("sqlite::memory:").await?;
        sqlx::migrate!("./migrations").run(&pool).await?;
        Ok(Self { pool })
    }

    pub async fn create_session(
        &self,
        root_id: String,
        workspace_path: String,
        source_kind: String,
        agent_kind: String,
    ) -> anyhow::Result<String> {
        let id = format!("sess_{}", Uuid::new_v4());

        sqlx::query(
            "insert into sessions (id, root_id, workspace_path, source_kind, agent_kind, status, created_at, updated_at)
             values (?1, ?2, ?3, ?4, ?5, 'created', datetime('now'), datetime('now'))",
        )
        .bind(&id)
        .bind(root_id)
        .bind(workspace_path)
        .bind(source_kind)
        .bind(agent_kind)
        .execute(&self.pool)
        .await?;

        Ok(id)
    }

    pub async fn append_event(
        &self,
        session_id: &str,
        event_type: &str,
        payload_json: &str,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "insert into session_events (session_id, event_type, payload_json, created_at)
             values (?1, ?2, ?3, datetime('now'))",
        )
        .bind(session_id)
        .bind(event_type)
        .bind(payload_json)
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    pub async fn load_snapshot(&self, session_id: &str) -> anyhow::Result<SessionSnapshot> {
        let session_row = sqlx::query(
            "select id, root_id, workspace_path, source_kind, agent_kind, status
             from sessions
             where id = ?1",
        )
        .bind(session_id)
        .fetch_one(&self.pool)
        .await?;

        let session = SessionRecord {
            id: session_row.get("id"),
            root_id: session_row.get("root_id"),
            workspace_path: session_row.get("workspace_path"),
            source_kind: session_row.get("source_kind"),
            agent_kind: session_row.get("agent_kind"),
            status: session_row.get("status"),
        };

        let event_rows = sqlx::query(
            "select id, event_type, payload_json
             from session_events
             where session_id = ?1
             order by id asc",
        )
        .bind(session_id)
        .fetch_all(&self.pool)
        .await?;

        let events = event_rows
            .into_iter()
            .map(|row| StoredEvent {
                id: row.get("id"),
                event_type: row.get("event_type"),
                payload_json: row.get("payload_json"),
            })
            .collect();

        Ok(SessionSnapshot { session, events })
    }
}
