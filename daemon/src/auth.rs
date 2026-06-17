use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use crate::user::store::SqliteUserStore;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CurrentUser {
    pub id: String,
    pub display_name: String,
    pub username: String,
    pub is_admin: bool,
}

#[derive(Clone)]
pub struct AuthState {
    users: SqliteUserStore,
    sessions: Arc<Mutex<HashMap<String, CurrentUser>>>,
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
        self.sessions.lock().unwrap().get(token).cloned()
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
                .retain(|_, current_user| current_user.id != user_id);
            Ok(DeleteUserResult::Deleted)
        } else {
            Ok(DeleteUserResult::NotFound)
        }
    }

    fn create_session(&self, user: CurrentUser) -> String {
        let token = uuid::Uuid::new_v4().to_string();
        self.sessions.lock().unwrap().insert(token.clone(), user);
        token
    }

    pub fn is_authenticated(&self, token: &str) -> bool {
        self.sessions.lock().unwrap().contains_key(token)
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
