import { useEffect, useState } from "react";

import type { WorkspaceEntryListing, WorkspaceFile } from "../types";
import { MarkdownContent } from "./MarkdownContent";

export function SessionFilesView(props: {
  sessionId: string;
  title: string;
  loadEntries: (sessionId: string, path: string) => Promise<WorkspaceEntryListing>;
  loadFile: (sessionId: string, path: string) => Promise<WorkspaceFile>;
  onClose: () => void;
}) {
  const [listing, setListing] = useState<WorkspaceEntryListing | null>(null);
  const [selectedFile, setSelectedFile] = useState<WorkspaceFile | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loadingPath, setLoadingPath] = useState<string | null>(".");

  async function openDirectory(path: string): Promise<void> {
    setLoadingPath(path);
    setError(null);
    setSelectedFile(null);
    try {
      setListing(await props.loadEntries(props.sessionId, path));
    } catch (error) {
      setError(error instanceof Error ? error.message : String(error));
    } finally {
      setLoadingPath(null);
    }
  }

  async function openFile(path: string): Promise<void> {
    setLoadingPath(path);
    setError(null);
    try {
      setSelectedFile(await props.loadFile(props.sessionId, path));
    } catch (error) {
      setError(error instanceof Error ? error.message : String(error));
    } finally {
      setLoadingPath(null);
    }
  }

  useEffect(() => {
    void openDirectory(".");
  }, [props.sessionId]);

  return (
    <div className="session-modal-backdrop">
      <section className="session-modal session-files-modal" role="dialog" aria-modal="true" aria-label="Session files">
        <header className="session-files-header">
          <div>
            <p className="eyebrow">Workspace files</p>
            <h2>{props.title}</h2>
          </div>
          <button className="session-modal-secondary" type="button" onClick={props.onClose}>
            Close
          </button>
        </header>

        {error ? <p className="form-error" role="alert">{error}</p> : null}

        <div className="session-files-grid">
          <aside className="session-files-browser">
            <div className="session-files-path">
              <span>{listing?.currentPath ?? "."}</span>
              {loadingPath ? <small>Loading {loadingPath}...</small> : null}
            </div>
            {listing?.parentPath ? (
              <button className="session-file-row" type="button" onClick={() => void openDirectory(listing.parentPath ?? ".")}>
                <span>..</span>
              </button>
            ) : null}
            <div className="session-files-list">
              {listing?.entries.map((entry) => (
                <button
                  key={`${entry.kind}:${entry.path}`}
                  className="session-file-row"
                  type="button"
                  aria-label={`Open ${entry.kind === "directory" ? "directory" : "file"} ${entry.name}`}
                  onClick={() => {
                    if (entry.kind === "directory") {
                      void openDirectory(entry.path);
                    } else {
                      void openFile(entry.path);
                    }
                  }}
                >
                  <span className="session-file-kind" aria-hidden="true">
                    {entry.kind === "directory" ? "dir" : "file"}
                  </span>
                  <span>{entry.name}</span>
                </button>
              ))}
            </div>
          </aside>

          <article className="session-file-preview">
            {selectedFile ? (
              <>
                <div className="session-file-preview-header">
                  <h3>{selectedFile.name}</h3>
                  <span>{selectedFile.renderMode === "markdown" ? "Markdown preview" : "Text preview"}</span>
                </div>
                {selectedFile.renderMode === "markdown" ? (
                  <MarkdownContent text={selectedFile.content} />
                ) : (
                  <pre className="session-file-text-preview">{selectedFile.content}</pre>
                )}
              </>
            ) : (
              <p className="muted">Choose a text or Markdown file to preview it here.</p>
            )}
          </article>
        </div>
      </section>
    </div>
  );
}
