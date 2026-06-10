use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
pub struct LoginRequest {
    pub pin: String,
}

#[derive(Serialize)]
pub struct WorkspaceRootDto {
    pub id: String,
    pub label: String,
    pub path: String,
}
