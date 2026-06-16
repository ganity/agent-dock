import { describe, expect, it } from "vitest";

import { getSessionTitle } from "./sessionDisplay";

describe("getSessionTitle", () => {
  it("uses a non-empty explicit title first", () => {
    expect(
      getSessionTitle({
        id: "sess-1",
        title: "Launch Pad",
        agentKind: "codex",
        workspacePath: "/tmp/workspace/apps/api",
      }),
    ).toBe("Launch Pad");
  });

  it("falls back to the last workspace path segment", () => {
    expect(
      getSessionTitle({
        id: "sess-1",
        title: "",
        agentKind: "codex",
        workspacePath: "/tmp/workspace/apps/api/",
      }),
    ).toBe("api");
  });

  it("falls back to agent kind when no useful title or path exists", () => {
    expect(
      getSessionTitle({
        id: "sess-1",
        agentKind: "claude",
        workspacePath: "/",
      }),
    ).toBe("claude");
  });
});
