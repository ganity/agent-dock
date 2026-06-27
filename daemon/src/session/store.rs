use std::time::Duration;

use sqlx::{
    Row, SqlitePool,
    sqlite::{SqliteConnectOptions, SqlitePoolOptions},
};
use uuid::Uuid;

use crate::session::model::{
    PendingUserMessage, SessionRecord, SessionSnapshot, SessionSummary, StoredEvent,
};

pub struct SqliteSessionStore {
    pool: SqlitePool,
}

impl SqliteSessionStore {
    pub async fn in_memory() -> anyhow::Result<Self> {
        let options = SqliteConnectOptions::new()
            .in_memory(true)
            .busy_timeout(Duration::from_secs(10));
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await?;
        sqlx::migrate!("./migrations").run(&pool).await?;
        Ok(Self { pool })
    }

    pub async fn from_path(path: &std::path::Path) -> anyhow::Result<Self> {
        if let Some(parent) = path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }

        let options = SqliteConnectOptions::new()
            .filename(path)
            .create_if_missing(true)
            .busy_timeout(Duration::from_secs(10));
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await?;
        sqlx::migrate!("./migrations").run(&pool).await?;
        Ok(Self { pool })
    }

    pub async fn create_session(
        &self,
        owner_user_id: String,
        root_id: String,
        workspace_path: String,
        source_kind: String,
        agent_kind: String,
        title: Option<String>,
    ) -> anyhow::Result<String> {
        let id = format!("sess_{}", Uuid::new_v4());

        sqlx::query(
            "insert into sessions (id, owner_user_id, root_id, workspace_path, source_kind, agent_kind, title, runtime_session_id, status, runtime_health, runtime_error_kind, runtime_error_message, created_at, updated_at)
             values (?1, ?2, ?3, ?4, ?5, ?6, ?7, null, 'created', 'unknown', null, null, datetime('now'), datetime('now'))",
        )
        .bind(&id)
        .bind(owner_user_id)
        .bind(root_id)
        .bind(workspace_path)
        .bind(source_kind)
        .bind(agent_kind)
        .bind(title)
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
        self.append_event_returning_id(session_id, event_type, payload_json)
            .await?;

        Ok(())
    }

    pub async fn append_event_returning_id(
        &self,
        session_id: &str,
        event_type: &str,
        payload_json: &str,
    ) -> anyhow::Result<i64> {
        let result = sqlx::query(
            "insert into session_events (session_id, event_type, payload_json, created_at)
             select ?1, ?2, ?3, datetime('now')
             from sessions
             where id = ?1
             limit 1",
        )
        .bind(session_id)
        .bind(event_type)
        .bind(payload_json)
        .execute(&self.pool)
        .await?;

        Ok(result.last_insert_rowid())
    }

    pub async fn append_user_message_event(
        &self,
        session_id: &str,
        client_message_id: Option<&str>,
        text: &str,
        image_paths: &[String],
    ) -> anyhow::Result<i64> {
        let mut payload = serde_json::json!({ "text": text, "imagePaths": image_paths });
        if let Some(client_message_id) = client_message_id {
            payload["clientMessageId"] = serde_json::Value::String(client_message_id.to_string());
        }

        let mut transaction = self.pool.begin().await?;
        let event_id = sqlx::query(
            "insert into session_events (session_id, event_type, payload_json, created_at)
             select ?1, 'user.message', ?2, datetime('now')
             from sessions
             where id = ?1
             limit 1",
        )
        .bind(session_id)
        .bind(payload.to_string())
        .execute(&mut *transaction)
        .await?
        .last_insert_rowid();

        if let Some(client_message_id) = client_message_id {
            sqlx::query(
                "insert or ignore into session_message_receipts (session_id, client_message_id, event_id, created_at)
                 values (?1, ?2, ?3, datetime('now'))",
            )
            .bind(session_id)
            .bind(client_message_id)
            .bind(event_id)
            .execute(&mut *transaction)
            .await?;
        }

        transaction.commit().await?;
        Ok(event_id)
    }

    pub async fn append_user_message_and_enqueue_pending(
        &self,
        session_id: &str,
        client_message_id: Option<&str>,
        text: String,
        image_paths: &[String],
    ) -> anyhow::Result<(i64, i64)> {
        let image_paths_json = serde_json::to_string(image_paths)?;
        let mut payload = serde_json::json!({ "text": text, "imagePaths": image_paths });
        if let Some(client_message_id) = client_message_id {
            payload["clientMessageId"] = serde_json::Value::String(client_message_id.to_string());
        }
        let payload_json = payload.to_string();
        let mut transaction = self.pool.begin().await?;

        let event_id = sqlx::query(
            "insert into session_events (session_id, event_type, payload_json, created_at)
             select ?1, 'user.message', ?2, datetime('now')
             from sessions
             where id = ?1
             limit 1",
        )
        .bind(session_id)
        .bind(payload_json)
        .execute(&mut *transaction)
        .await?
        .last_insert_rowid();

        if let Some(client_message_id) = client_message_id {
            sqlx::query(
                "insert or ignore into session_message_receipts (session_id, client_message_id, event_id, created_at)
                 values (?1, ?2, ?3, datetime('now'))",
            )
            .bind(session_id)
            .bind(client_message_id)
            .bind(event_id)
            .execute(&mut *transaction)
            .await?;
        }

        let pending_id = sqlx::query(
            "insert into pending_user_messages (session_id, text, image_paths_json, created_at)
             values (?1, ?2, ?3, datetime('now'))
             returning id",
        )
        .bind(session_id)
        .bind(text)
        .bind(image_paths_json)
        .fetch_one(&mut *transaction)
        .await?
        .get("id");

        transaction.commit().await?;
        Ok((event_id, pending_id))
    }

    pub async fn message_receipt_event_id(
        &self,
        session_id: &str,
        client_message_id: &str,
    ) -> anyhow::Result<Option<i64>> {
        let event_id = sqlx::query_scalar::<_, Option<i64>>(
            "select event_id
             from session_message_receipts
             where session_id = ?1 and client_message_id = ?2",
        )
        .bind(session_id)
        .bind(client_message_id)
        .fetch_optional(&self.pool)
        .await?
        .flatten();

        Ok(event_id)
    }

    pub async fn record_message_receipt(
        &self,
        session_id: &str,
        client_message_id: &str,
        event_id: i64,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "insert or ignore into session_message_receipts (session_id, client_message_id, event_id, created_at)
             values (?1, ?2, ?3, datetime('now'))",
        )
        .bind(session_id)
        .bind(client_message_id)
        .bind(event_id)
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    pub async fn pending_user_messages(
        &self,
        session_id: &str,
    ) -> anyhow::Result<Vec<PendingUserMessage>> {
        let rows = sqlx::query(
            "select id, text, image_paths_json
             from pending_user_messages
             where session_id = ?1 and status = 'pending'
             order by id asc",
        )
        .bind(session_id)
        .fetch_all(&self.pool)
        .await?;

        rows.into_iter().map(row_to_pending_user_message).collect()
    }

    pub async fn in_flight_user_message(
        &self,
        session_id: &str,
    ) -> anyhow::Result<Option<PendingUserMessage>> {
        let row = sqlx::query(
            "select id, text, image_paths_json
             from pending_user_messages
             where session_id = ?1 and status = 'in_flight'
             order by id asc
             limit 1",
        )
        .bind(session_id)
        .fetch_optional(&self.pool)
        .await?;

        row.map(row_to_pending_user_message).transpose()
    }

    pub async fn claim_next_pending_user_message(
        &self,
        session_id: &str,
    ) -> anyhow::Result<Option<PendingUserMessage>> {
        let mut transaction = self.pool.begin().await?;
        let row = sqlx::query(
            "select id, text, image_paths_json
             from pending_user_messages
             where session_id = ?1 and status = 'pending'
             order by id asc
             limit 1",
        )
        .bind(session_id)
        .fetch_optional(&mut *transaction)
        .await?;

        let Some(row) = row else {
            transaction.commit().await?;
            return Ok(None);
        };

        let message = row_to_pending_user_message(row)?;
        sqlx::query(
            "update pending_user_messages
             set status = 'in_flight', sent_at = datetime('now')
             where session_id = ?1 and id = ?2 and status = 'pending'",
        )
        .bind(session_id)
        .bind(message.id)
        .execute(&mut *transaction)
        .await?;

        transaction.commit().await?;
        Ok(Some(message))
    }

    pub async fn ack_in_flight_user_message(
        &self,
        session_id: &str,
        message_id: i64,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "delete from pending_user_messages
             where session_id = ?1 and id = ?2 and status = 'in_flight'",
        )
        .bind(session_id)
        .bind(message_id)
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    pub async fn reset_in_flight_user_messages(&self, session_id: &str) -> anyhow::Result<()> {
        sqlx::query(
            "update pending_user_messages
             set status = 'pending', sent_at = null
             where session_id = ?1 and status = 'in_flight'",
        )
        .bind(session_id)
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    pub async fn delete_pending_user_message(
        &self,
        session_id: &str,
        message_id: i64,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "delete from pending_user_messages
             where session_id = ?1 and id = ?2 and status = 'pending'",
        )
        .bind(session_id)
        .bind(message_id)
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    pub async fn list_sessions(&self, owner_user_id: &str) -> anyhow::Result<Vec<SessionSummary>> {
        let rows = sqlx::query(
            "select id, owner_user_id, workspace_path, source_kind, agent_kind, title, runtime_session_id, status, runtime_health, runtime_error_kind, runtime_error_message
             from sessions
             where owner_user_id = ?1
             order by updated_at desc, id desc",
        )
        .bind(owner_user_id)
        .fetch_all(&self.pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|row| SessionSummary {
                id: row.get("id"),
                owner_user_id: row.get("owner_user_id"),
                workspace_path: row.get("workspace_path"),
                source_kind: row.get("source_kind"),
                agent_kind: row.get("agent_kind"),
                title: row.get("title"),
                runtime_session_id: row.get("runtime_session_id"),
                status: row.get("status"),
                runtime_health: row.get("runtime_health"),
                runtime_error_kind: row.get("runtime_error_kind"),
                runtime_error_message: row.get("runtime_error_message"),
            })
            .collect())
    }

    pub async fn events_after(
        &self,
        session_id: &str,
        cursor: i64,
    ) -> anyhow::Result<Vec<StoredEvent>> {
        let rows = sqlx::query(
            "select id, event_type, payload_json
             from session_events
             where session_id = ?1 and id > ?2
             order by id asc",
        )
        .bind(session_id)
        .bind(cursor)
        .fetch_all(&self.pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|row| StoredEvent {
                id: row.get("id"),
                event_type: row.get("event_type"),
                payload_json: row.get("payload_json"),
            })
            .collect())
    }

    pub async fn latest_event_id(&self, session_id: &str) -> anyhow::Result<Option<i64>> {
        let latest = sqlx::query_scalar::<_, Option<i64>>(
            "select max(id)
             from session_events
             where session_id = ?1",
        )
        .bind(session_id)
        .fetch_one(&self.pool)
        .await?;

        Ok(latest)
    }

    pub async fn update_session_status(
        &self,
        session_id: &str,
        status: &str,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "update sessions
             set status = ?2, updated_at = datetime('now')
             where id = ?1",
        )
        .bind(session_id)
        .bind(status)
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    pub async fn update_runtime_session_id(
        &self,
        session_id: &str,
        runtime_session_id: &str,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "update sessions
             set runtime_session_id = ?2, updated_at = datetime('now')
             where id = ?1",
        )
        .bind(session_id)
        .bind(runtime_session_id)
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    pub async fn update_runtime_health(
        &self,
        session_id: &str,
        runtime_health: &str,
        runtime_error_kind: Option<&str>,
        runtime_error_message: Option<&str>,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "update sessions
             set runtime_health = ?2, runtime_error_kind = ?3, runtime_error_message = ?4, updated_at = datetime('now')
             where id = ?1",
        )
        .bind(session_id)
        .bind(runtime_health)
        .bind(runtime_error_kind)
        .bind(runtime_error_message)
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    pub async fn load_snapshot(&self, session_id: &str) -> anyhow::Result<SessionSnapshot> {
        self.load_snapshot_window(session_id, None, None).await
    }

    pub async fn load_snapshot_window(
        &self,
        session_id: &str,
        limit: Option<usize>,
        before: Option<i64>,
    ) -> anyhow::Result<SessionSnapshot> {
        let session_row = sqlx::query(
            "select id, owner_user_id, root_id, workspace_path, source_kind, agent_kind, title, runtime_session_id, status, runtime_health, runtime_error_kind, runtime_error_message
             from sessions
             where id = ?1",
        )
        .bind(session_id)
        .fetch_one(&self.pool)
        .await?;

        let session = SessionRecord {
            id: session_row.get("id"),
            owner_user_id: session_row.get("owner_user_id"),
            root_id: session_row.get("root_id"),
            workspace_path: session_row.get("workspace_path"),
            source_kind: session_row.get("source_kind"),
            agent_kind: session_row.get("agent_kind"),
            title: session_row.get("title"),
            runtime_session_id: session_row.get("runtime_session_id"),
            status: session_row.get("status"),
            runtime_health: session_row.get("runtime_health"),
            runtime_error_kind: session_row.get("runtime_error_kind"),
            runtime_error_message: session_row.get("runtime_error_message"),
        };

        let (events, has_more_history) = match limit {
            Some(limit) => self.load_event_window(session_id, limit, before).await?,
            None => {
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

                (events, false)
            }
        };

        Ok(SessionSnapshot {
            session,
            events,
            has_more_history,
        })
    }

    pub async fn delete_session(&self, session_id: &str) -> anyhow::Result<bool> {
        let mut transaction = self.pool.begin().await?;

        sqlx::query("delete from session_events where session_id = ?1")
            .bind(session_id)
            .execute(&mut *transaction)
            .await?;

        sqlx::query("delete from pending_user_messages where session_id = ?1")
            .bind(session_id)
            .execute(&mut *transaction)
            .await?;

        sqlx::query("delete from session_message_receipts where session_id = ?1")
            .bind(session_id)
            .execute(&mut *transaction)
            .await?;

        let deleted = sqlx::query("delete from sessions where id = ?1")
            .bind(session_id)
            .execute(&mut *transaction)
            .await?
            .rows_affected()
            > 0;

        transaction.commit().await?;
        Ok(deleted)
    }

    async fn load_event_window(
        &self,
        session_id: &str,
        limit: usize,
        before: Option<i64>,
    ) -> anyhow::Result<(Vec<StoredEvent>, bool)> {
        let limit = i64::try_from(limit)?;

        let event_rows = if let Some(before) = before {
            sqlx::query(
                "select id, event_type, payload_json
                 from session_events
                 where session_id = ?1 and id < ?2
                 order by id desc
                 limit ?3",
            )
            .bind(session_id)
            .bind(before)
            .bind(limit)
            .fetch_all(&self.pool)
            .await?
        } else {
            sqlx::query(
                "select id, event_type, payload_json
                 from session_events
                 where session_id = ?1
                 order by id desc
                 limit ?2",
            )
            .bind(session_id)
            .bind(limit)
            .fetch_all(&self.pool)
            .await?
        };

        let mut events = event_rows
            .into_iter()
            .map(|row| StoredEvent {
                id: row.get("id"),
                event_type: row.get("event_type"),
                payload_json: row.get("payload_json"),
            })
            .collect::<Vec<_>>();
        events.reverse();

        let has_more_history = if let Some(first) = events.first() {
            let count = sqlx::query_scalar::<_, i64>(
                "select count(1)
                 from session_events
                 where session_id = ?1 and id < ?2",
            )
            .bind(session_id)
            .bind(first.id)
            .fetch_one(&self.pool)
            .await?;
            count > 0
        } else {
            false
        };

        Ok((events, has_more_history))
    }

    pub async fn close_for_test(&self) {
        self.pool.close().await;
    }
}

fn row_to_pending_user_message(row: sqlx::sqlite::SqliteRow) -> anyhow::Result<PendingUserMessage> {
    let image_paths_json: String = row.get("image_paths_json");
    let image_paths = serde_json::from_str(&image_paths_json)?;

    Ok(PendingUserMessage {
        id: row.get("id"),
        text: row.get("text"),
        image_paths,
    })
}
