use crate::config::WorkspaceRoot;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq)]
pub struct WorkspaceDirectoryEntry {
    pub name: String,
    pub path: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct WorkspaceDirectoryListing {
    pub current_path: String,
    pub parent_path: Option<String>,
    pub directories: Vec<WorkspaceDirectoryEntry>,
}

pub fn list_roots(roots: &[WorkspaceRoot]) -> Vec<WorkspaceRoot> {
    roots.to_vec()
}

pub fn list_directories(path: &str) -> anyhow::Result<WorkspaceDirectoryListing> {
    let requested = std::fs::canonicalize(path)?;
    if !requested.is_dir() {
        anyhow::bail!("path must be a directory");
    }

    let mut directories = std::fs::read_dir(&requested)?
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let path = entry.path();
            if !path.is_dir() {
                return None;
            }

            Some(WorkspaceDirectoryEntry {
                name: entry.file_name().to_string_lossy().into_owned(),
                path: path.to_string_lossy().into_owned(),
            })
        })
        .collect::<Vec<_>>();

    directories.sort_by(|left, right| left.name.cmp(&right.name));

    let parent_path = requested.parent().map(Path::to_path_buf).map(path_to_string);

    Ok(WorkspaceDirectoryListing {
        current_path: path_to_string(requested),
        parent_path,
        directories,
    })
}

fn path_to_string(path: PathBuf) -> String {
    path.to_string_lossy().into_owned()
}
