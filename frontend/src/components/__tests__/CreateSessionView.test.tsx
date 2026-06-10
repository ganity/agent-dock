import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { CreateSessionView } from "../CreateSessionView";

describe("CreateSessionView", () => {
  it("submits the selected root, path, and agent", () => {
    const onSubmit = vi.fn();

    render(
      <CreateSessionView
        roots={[
          { id: "workspace", label: "Workspace", path: "/tmp/workspace" },
          { id: "alt", label: "Alt", path: "/tmp/alt" },
        ]}
        onSubmit={onSubmit}
      />,
    );

    fireEvent.change(screen.getByLabelText("Agent"), { target: { value: "codex" } });
    fireEvent.change(screen.getByLabelText("Workspace"), { target: { value: "alt" } });
    fireEvent.change(screen.getByLabelText("Path"), { target: { value: "apps/api" } });
    fireEvent.click(screen.getByRole("button", { name: "Create session" }));

    expect(onSubmit).toHaveBeenCalledWith({
      rootId: "alt",
      path: "apps/api",
      agentKind: "codex",
    });
  });
});
