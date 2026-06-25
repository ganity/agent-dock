use crate::config::WorkspaceRoot;
use std::path::{Component, Path, PathBuf};

const MAX_TEXT_FILE_BYTES: u64 = 1024 * 1024;

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

#[derive(Clone, Debug, PartialEq)]
pub struct WorkspaceEntry {
    pub name: String,
    pub path: String,
    pub kind: WorkspaceEntryKind,
}

#[derive(Clone, Debug, PartialEq)]
pub enum WorkspaceEntryKind {
    Directory,
    File,
}

#[derive(Clone, Debug, PartialEq)]
pub struct WorkspaceEntryListing {
    pub current_path: String,
    pub parent_path: Option<String>,
    pub entries: Vec<WorkspaceEntry>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct WorkspaceFile {
    pub name: String,
    pub path: String,
    pub content: String,
    pub render_mode: WorkspaceFileRenderMode,
}

#[derive(Clone, Debug, PartialEq)]
pub enum WorkspaceFileRenderMode {
    Markdown,
    Text,
}

#[derive(Clone, Debug, PartialEq)]
pub enum WorkspaceFileError {
    Forbidden,
    NotFound,
    NotDirectory,
    NotFile,
    TooLarge,
    InvalidUtf8,
    Io(String),
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

    let parent_path = requested
        .parent()
        .map(Path::to_path_buf)
        .map(path_to_string);

    Ok(WorkspaceDirectoryListing {
        current_path: path_to_string(requested),
        parent_path,
        directories,
    })
}

pub fn list_workspace_entries(
    workspace_path: &str,
    relative_path: &str,
) -> Result<WorkspaceEntryListing, WorkspaceFileError> {
    let root = canonicalize_existing(Path::new(workspace_path))?;
    let requested = resolve_inside_workspace(&root, relative_path)?;
    if !requested.is_dir() {
        return Err(WorkspaceFileError::NotDirectory);
    }

    let mut entries = std::fs::read_dir(&requested)
        .map_err(|error| WorkspaceFileError::Io(error.to_string()))?
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let file_type = entry.file_type().ok()?;
            if !file_type.is_dir() && !file_type.is_file() {
                return None;
            }
            let path = entry.path();
            let relative = relative_path_from_root(&root, &path).ok()?;
            Some(WorkspaceEntry {
                name: entry.file_name().to_string_lossy().into_owned(),
                path: relative,
                kind: if file_type.is_dir() {
                    WorkspaceEntryKind::Directory
                } else {
                    WorkspaceEntryKind::File
                },
            })
        })
        .collect::<Vec<_>>();

    entries.sort_by(|left, right| match (&left.kind, &right.kind) {
        (WorkspaceEntryKind::Directory, WorkspaceEntryKind::File) => std::cmp::Ordering::Less,
        (WorkspaceEntryKind::File, WorkspaceEntryKind::Directory) => std::cmp::Ordering::Greater,
        _ => left.name.cmp(&right.name),
    });

    let current_path = relative_path_from_root(&root, &requested)?;
    let parent_path = requested
        .parent()
        .filter(|parent| *parent != requested)
        .and_then(|parent| relative_path_from_root(&root, parent).ok());

    Ok(WorkspaceEntryListing {
        current_path,
        parent_path,
        entries,
    })
}

pub fn read_workspace_text_file(
    workspace_path: &str,
    relative_path: &str,
) -> Result<WorkspaceFile, WorkspaceFileError> {
    let root = canonicalize_existing(Path::new(workspace_path))?;
    let requested = resolve_inside_workspace(&root, relative_path)?;
    if !requested.is_file() {
        return Err(WorkspaceFileError::NotFile);
    }

    let metadata = requested
        .metadata()
        .map_err(|error| WorkspaceFileError::Io(error.to_string()))?;
    if metadata.len() > MAX_TEXT_FILE_BYTES {
        return Err(WorkspaceFileError::TooLarge);
    }

    let bytes =
        std::fs::read(&requested).map_err(|error| WorkspaceFileError::Io(error.to_string()))?;
    let content = String::from_utf8(bytes).map_err(|_| WorkspaceFileError::InvalidUtf8)?;
    let path = relative_path_from_root(&root, &requested)?;
    let name = requested
        .file_name()
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.clone());
    let render_mode = if is_markdown_file(&name) {
        WorkspaceFileRenderMode::Markdown
    } else {
        WorkspaceFileRenderMode::Text
    };

    Ok(WorkspaceFile {
        name,
        path,
        content,
        render_mode,
    })
}

fn canonicalize_existing(path: &Path) -> Result<PathBuf, WorkspaceFileError> {
    std::fs::canonicalize(path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            WorkspaceFileError::NotFound
        } else {
            WorkspaceFileError::Io(error.to_string())
        }
    })
}

fn resolve_inside_workspace(
    root: &Path,
    relative_path: &str,
) -> Result<PathBuf, WorkspaceFileError> {
    let candidate = Path::new(relative_path);
    if candidate.is_absolute()
        || candidate
            .components()
            .any(|component| matches!(component, Component::ParentDir))
    {
        return Err(WorkspaceFileError::Forbidden);
    }

    let joined = root.join(candidate);
    let resolved = canonicalize_existing(&joined)?;
    if !resolved.starts_with(root) {
        return Err(WorkspaceFileError::Forbidden);
    }
    Ok(resolved)
}

fn relative_path_from_root(root: &Path, path: &Path) -> Result<String, WorkspaceFileError> {
    let relative = path
        .strip_prefix(root)
        .map_err(|_| WorkspaceFileError::Forbidden)?;
    if relative.as_os_str().is_empty() {
        return Ok(".".into());
    }
    Ok(relative.to_string_lossy().into_owned())
}

fn is_markdown_file(name: &str) -> bool {
    let name = name.to_lowercase();
    name.ends_with(".md") || name.ends_with(".markdown")
}

fn path_to_string(path: PathBuf) -> String {
    path.to_string_lossy().into_owned()
}
