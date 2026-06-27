use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};

use crate::user::store::SqliteUserStore;

/// Default session lifetime: 7 days.
const DEFAULT_SESSION_TTL: Duration = Duration::from_secs(7 * 24 * 3600);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CurrentUser {
    pub id: String,
    pub display_name: String,
    pub username: String,
    pub is_admin: bool,
}

/// A session entry that tracks when it was created for TTL enforcement.
struct SessionEntry {
    user: CurrentUser,
    created_at: std::time::Instant,
}

#[derive(Clone)]
pub struct AuthState {
    users: SqliteUserStore,
    sessions: Arc<Mutex<HashMap<String, SessionEntry>>>,
    session_ttl: Duration,
}

pub enum CreateUserError {
    UsernameTaken,
    InvalidInput,
    Unexpected(anyhow::Error),
}

pub enum DeleteUserResult {
    Deleted,
    NotFound,
    LastAdmin,
}

impl AuthState {
    pub fn new(users: SqliteUserStore) -> Self {
        Self {
            users,
            sessions: Arc::new(Mutex::new(HashMap::new())),
            session_ttl: DEFAULT_SESSION_TTL,
        }
    }

    pub async fn login_user(&self, username: &str, password: &str) -> Option<String> {
        let username = username.trim();
        if username.is_empty() {
            return None;
        }

        let user = self.users.find_by_username(username).await.ok()??;
        if !self.users.verify_password(&user, password) {
            return None;
        }

        Some(self.create_session(CurrentUser {
            id: user.id,
            display_name: display_name(&user.username),
            username: user.username,
            is_admin: user.is_admin,
        }))
    }

    pub fn current_user(&self, token: &str) -> Option<CurrentUser> {
        let sessions = self.sessions.lock().unwrap();
        let entry = sessions.get(token)?;

        // Check if the session has expired
        if entry.created_at.elapsed() > self.session_ttl {
            return None;
        }

        Some(entry.user.clone())
    }

    pub async fn list_users(&self) -> anyhow::Result<Vec<crate::user::store::StoredUser>> {
        self.users.list_users().await
    }

    pub async fn create_user(
        &self,
        username: &str,
        password: &str,
        is_admin: bool,
    ) -> Result<crate::user::store::StoredUser, CreateUserError> {
        let username = username.trim();
        let password = password.trim();
        if username.is_empty() || password.is_empty() {
            return Err(CreateUserError::InvalidInput);
        }

        if self
            .users
            .find_by_username(username)
            .await
            .map_err(CreateUserError::Unexpected)?
            .is_some()
        {
            return Err(CreateUserError::UsernameTaken);
        }

        let id = if username == "admin" {
            "usr_workspace".into()
        } else {
            format!("usr_{}", stable_user_slug(username))
        };

        self.users
            .create_user(&id, username, password, is_admin)
            .await
            .map_err(CreateUserError::Unexpected)
    }

    pub async fn reset_password(&self, user_id: &str, password: &str) -> anyhow::Result<bool> {
        self.users.update_password(user_id, password).await
    }

    pub async fn delete_user(&self, user_id: &str) -> anyhow::Result<DeleteUserResult> {
        let Some(user) = self.users.find_by_id(user_id).await? else {
            return Ok(DeleteUserResult::NotFound);
        };

        if user.is_admin && self.users.count_admins().await? <= 1 {
            return Ok(DeleteUserResult::LastAdmin);
        }

        let deleted = self.users.delete_user(user_id).await?;
        if deleted {
            self.sessions
                .lock()
                .unwrap()
                .retain(|_, entry| entry.user.id != user_id);
            Ok(DeleteUserResult::Deleted)
        } else {
            Ok(DeleteUserResult::NotFound)
        }
    }

    fn create_session(&self, user: CurrentUser) -> String {
        let token = uuid::Uuid::new_v4().to_string();
        self.sessions.lock().unwrap().insert(
            token.clone(),
            SessionEntry {
                user,
                created_at: std::time::Instant::now(),
            },
        );
        token
    }

    pub fn is_authenticated(&self, token: &str) -> bool {
        self.current_user(token).is_some()
    }

    /// Evict expired sessions. Should be called periodically.
    pub fn evict_expired_sessions(&self) {
        let mut sessions = self.sessions.lock().unwrap();
        let ttl = self.session_ttl;
        sessions.retain(|_, entry| entry.created_at.elapsed() <= ttl);
    }
}

fn stable_user_slug(username: &str) -> String {
    let slug = username
        .chars()
        .map(|value| {
            if value.is_ascii_alphanumeric() {
                value.to_ascii_lowercase()
            } else {
                '_'
            }
        })
        .collect::<String>()
        .trim_matches('_')
        .to_string();

    if slug.is_empty() {
        "user".into()
    } else {
        slug
    }
}

fn display_name(username: &str) -> String {
    let mut chars = username.trim().chars();
    let Some(first) = chars.next() else {
        return "User".into();
    };

    format!("{}{}", first.to_uppercase(), chars.as_str())
}
