import { useEffect, useState } from "react";

import type { WorkspaceDirectoryListing } from "../types";

export function PathPicker(props: {
  path: string;
  rootPath?: string;
  errorId?: string;
  invalid?: boolean;
  onBlur?: () => void;
  onChange: (path: string) => void;
  loadDirectories: (path: string) => Promise<WorkspaceDirectoryListing>;
}) {
  const [listing, setListing] = useState<WorkspaceDirectoryListing | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setListing(null);
    setError(null);
    setLoading(false);
  }, [props.rootPath]);

  async function openDirectory(path: string): Promise<void> {
    setLoading(true);
    setError(null);

    try {
      setListing(await props.loadDirectories(path));
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : String(loadError));
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="field">
      <span>Path</span>
      <input
        aria-label="Path"
        aria-describedby={props.errorId}
        aria-invalid={props.invalid ? "true" : "false"}
        className="input"
        value={props.path}
        onBlur={props.onBlur}
        onChange={(event) => props.onChange(event.target.value)}
      />
      <div className="path-picker-actions">
        <button
          className="button button-quiet"
          type="button"
          onClick={() => void openDirectory(props.path.trim() || props.rootPath || "/")}
        >
          Browse directories
        </button>
      </div>
      {loading ? <p className="muted">Loading directories...</p> : null}
      {error ? (
        <p className="form-error" role="alert">
          {error}
        </p>
      ) : null}
      {listing ? (
        <section className="path-picker-browser">
          <p className="modal-root-hint">Current: {listing.currentPath}</p>
          {listing.parentPath ? (
            <button
              className="button button-quiet"
              type="button"
              onClick={() => void openDirectory(listing.parentPath!)}
            >
              ..
            </button>
          ) : null}
          <div className="path-picker-list">
            {listing.directories.map((directory) => (
              <button
                key={directory.path}
                className="button button-quiet"
                type="button"
                onClick={() => {
                  props.onChange(directory.path);
                }}
              >
                {directory.name}
              </button>
            ))}
          </div>
        </section>
      ) : null}
    </div>
  );
}
