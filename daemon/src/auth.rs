use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CurrentUser {
    pub id: String,
    pub display_name: String,
}

#[derive(Clone)]
pub struct AuthState {
    pin: Arc<String>,
    sessions: Arc<Mutex<HashMap<String, CurrentUser>>>,
}

impl AuthState {
    pub fn new(pin: String) -> Self {
        Self {
            pin: Arc::new(pin),
            sessions: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn login(&self, candidate: &str) -> Option<String> {
        if candidate != self.pin.as_str() {
            return None;
        }

        Some(self.create_session(default_user()))
    }

    pub fn login_user(&self, username: &str, password: &str) -> Option<String> {
        if password != self.pin.as_str() {
            return None;
        }

        let username = username.trim();
        if username.is_empty() {
            return None;
        }

        Some(self.create_session(CurrentUser {
            id: format!("usr_{}", stable_user_slug(username)),
            display_name: display_name(username),
        }))
    }

    pub fn current_user(&self, token: &str) -> Option<CurrentUser> {
        self.sessions.lock().unwrap().get(token).cloned()
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

fn default_user() -> CurrentUser {
    CurrentUser {
        id: "usr_workspace".into(),
        display_name: "Agent Dock".into(),
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
