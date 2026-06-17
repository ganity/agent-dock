use std::sync::Arc;

use anyhow::anyhow;
use argon2::{
    Argon2,
    password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
};
use sqlx::{
    Row,
    sqlite::{SqliteConnectOptions, SqlitePoolOptions},
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StoredUser {
    pub id: String,
    pub username: String,
    pub password_hash: String,
    pub is_admin: bool,
}

#[derive(Clone)]
pub struct SqliteUserStore {
    pool: Arc<sqlx::SqlitePool>,
}

impl SqliteUserStore {
    pub async fn from_path(path: &std::path::Path) -> anyhow::Result<Self> {
        if let Some(parent) = path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }

        let options = SqliteConnectOptions::new()
            .filename(path)
            .create_if_missing(true);
        let pool = SqlitePoolOptions::new().connect_with(options).await?;
        sqlx::migrate!("./migrations").run(&pool).await?;
        Ok(Self {
            pool: Arc::new(pool),
        })
    }

    pub async fn in_memory() -> anyhow::Result<Self> {
        let pool = sqlx::SqlitePool::connect("sqlite::memory:").await?;
        sqlx::migrate!("./migrations").run(&pool).await?;
        Ok(Self {
            pool: Arc::new(pool),
        })
    }

    pub async fn count_users(&self) -> anyhow::Result<i64> {
        let row = sqlx::query("select count(*) as count from users")
            .fetch_one(self.pool.as_ref())
            .await?;
        Ok(row.get("count"))
    }

    pub async fn count_admins(&self) -> anyhow::Result<i64> {
        let row = sqlx::query("select count(*) as count from users where is_admin = 1")
            .fetch_one(self.pool.as_ref())
            .await?;
        Ok(row.get("count"))
    }

    pub async fn list_users(&self) -> anyhow::Result<Vec<StoredUser>> {
        let rows = sqlx::query(
            "select id, username, password_hash, is_admin from users order by username asc",
        )
        .fetch_all(self.pool.as_ref())
        .await?;

        Ok(rows.into_iter().map(row_to_user).collect())
    }

    pub async fn find_by_username(&self, username: &str) -> anyhow::Result<Option<StoredUser>> {
        let row = sqlx::query(
            "select id, username, password_hash, is_admin from users where username = ?1",
        )
        .bind(username)
        .fetch_optional(self.pool.as_ref())
        .await?;

        Ok(row.map(row_to_user))
    }

    pub async fn find_by_id(&self, id: &str) -> anyhow::Result<Option<StoredUser>> {
        let row = sqlx::query(
            "select id, username, password_hash, is_admin from users where id = ?1",
        )
        .bind(id)
        .fetch_optional(self.pool.as_ref())
        .await?;

        Ok(row.map(row_to_user))
    }

    pub async fn create_user(
        &self,
        id: &str,
        username: &str,
        password: &str,
        is_admin: bool,
    ) -> anyhow::Result<StoredUser> {
        let password_hash = hash_password(password)?;
        sqlx::query(
            "insert into users (id, username, password_hash, is_admin, created_at)
             values (?1, ?2, ?3, ?4, datetime('now'))",
        )
        .bind(id)
        .bind(username)
        .bind(&password_hash)
        .bind(is_admin)
        .execute(self.pool.as_ref())
        .await?;

        Ok(StoredUser {
            id: id.into(),
            username: username.into(),
            password_hash,
            is_admin,
        })
    }

    pub async fn update_password(&self, id: &str, password: &str) -> anyhow::Result<bool> {
        let password_hash = hash_password(password)?;
        let affected = sqlx::query("update users set password_hash = ?2 where id = ?1")
            .bind(id)
            .bind(password_hash)
            .execute(self.pool.as_ref())
            .await?
            .rows_affected();
        Ok(affected > 0)
    }

    pub async fn delete_user(&self, id: &str) -> anyhow::Result<bool> {
        let affected = sqlx::query("delete from users where id = ?1")
            .bind(id)
            .execute(self.pool.as_ref())
            .await?
            .rows_affected();
        Ok(affected > 0)
    }

    pub async fn ensure_user(
        &self,
        id: &str,
        username: &str,
        password: &str,
        is_admin: bool,
    ) -> anyhow::Result<StoredUser> {
        if let Some(user) = self.find_by_id(id).await? {
            return Ok(user);
        }

        self.create_user(id, username, password, is_admin).await
    }

    pub fn verify_password(&self, user: &StoredUser, password: &str) -> bool {
        verify_password(&user.password_hash, password)
    }
}

fn row_to_user(row: sqlx::sqlite::SqliteRow) -> StoredUser {
    StoredUser {
        id: row.get("id"),
        username: row.get("username"),
        password_hash: row.get("password_hash"),
        is_admin: row.get::<i64, _>("is_admin") != 0,
    }
}

fn hash_password(password: &str) -> anyhow::Result<String> {
    let salt = SaltString::encode_b64(uuid::Uuid::new_v4().as_bytes())
        .map_err(|error| anyhow!("failed to create password salt: {error}"))?;
    Ok(Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map_err(|error| anyhow!("failed to hash password: {error}"))?
        .to_string())
}

fn verify_password(password_hash: &str, password: &str) -> bool {
    let Ok(hash) = PasswordHash::new(password_hash) else {
        return false;
    };
    Argon2::default()
        .verify_password(password.as_bytes(), &hash)
        .is_ok()
}
