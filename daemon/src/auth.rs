use std::{
    collections::HashSet,
    sync::{Arc, Mutex},
};

#[derive(Clone)]
pub struct AuthState {
    pin: Arc<String>,
    sessions: Arc<Mutex<HashSet<String>>>,
}

impl AuthState {
    pub fn new(pin: String) -> Self {
        Self {
            pin: Arc::new(pin),
            sessions: Arc::new(Mutex::new(HashSet::new())),
        }
    }

    pub fn login(&self, candidate: &str) -> Option<String> {
        if candidate != self.pin.as_str() {
            return None;
        }

        let token = uuid::Uuid::new_v4().to_string();
        self.sessions.lock().unwrap().insert(token.clone());
        Some(token)
    }

    pub fn is_authenticated(&self, token: &str) -> bool {
        self.sessions.lock().unwrap().contains(token)
    }
}
