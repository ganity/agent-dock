import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { AttachSessionView } from "../AttachSessionView";

describe("AttachSessionView", () => {
  it("submits runtime session metadata", () => {
    const onSubmit = vi.fn();

    render(
      <AttachSessionView
        roots={[{ id: "workspace", label: "Workspace", path: "/tmp/workspace" }]}
        onSubmit={onSubmit}
      />,
    );

    fireEvent.change(screen.getByLabelText("Agent"), { target: { value: "claude" } });
    fireEvent.change(screen.getByLabelText("Runtime session ID"), { target: { value: "thread-abc" } });
    fireEvent.change(screen.getByLabelText("Path"), { target: { value: "apps/api" } });
    fireEvent.click(screen.getByRole("button", { name: "Attach session" }));

    expect(onSubmit).toHaveBeenCalledWith({
      rootId: "workspace",
      path: "apps/api",
      agentKind: "claude",
      runtimeSessionId: "thread-abc",
    });
  });
});
