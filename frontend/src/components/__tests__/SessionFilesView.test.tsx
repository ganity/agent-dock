import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { SessionFilesView } from "../SessionFilesView";

afterEach(() => {
  cleanup();
});

describe("SessionFilesView", () => {
  it("browses session files and previews markdown files as rendered markdown", async () => {
    const loadEntries = vi.fn(async (_sessionId: string, path: string) => {
      if (path === ".") {
        return {
          currentPath: ".",
          parentPath: null,
          entries: [{ name: "docs", path: "docs", kind: "directory" as const }],
        };
      }

      return {
        currentPath: "docs",
        parentPath: ".",
        entries: [{ name: "design.md", path: "docs/design.md", kind: "file" as const }],
      };
    });
    const loadFile = vi.fn(async () => ({
      name: "design.md",
      path: "docs/design.md",
      renderMode: "markdown" as const,
      content: "## Design Preview\n\n- Render markdown\n",
    }));

    render(
      <SessionFilesView
        sessionId="sess-1"
        title="Launch Pad"
        loadEntries={loadEntries}
        loadFile={loadFile}
        onClose={vi.fn()}
      />,
    );

    fireEvent.click(await screen.findByRole("button", { name: "Open directory docs" }));
    fireEvent.click(await screen.findByRole("button", { name: "Open file design.md" }));

    expect(await screen.findByRole("heading", { level: 2, name: "Design Preview" })).toBeInTheDocument();
    expect(screen.getByText("Render markdown")).toBeInTheDocument();
    expect(screen.queryByText("## Design Preview")).not.toBeInTheDocument();
  });
});
