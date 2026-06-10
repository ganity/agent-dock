use crate::config::WorkspaceRoot;

pub fn list_roots(roots: &[WorkspaceRoot]) -> Vec<WorkspaceRoot> {
    roots.to_vec()
}
