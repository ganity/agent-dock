import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { SessionListView } from "../SessionListView";

describe("SessionListView", () => {
    it("renders session metadata and exposes the create action", () => {
        const onCreate = vi.fn();
        const onSelect = vi.fn();

        render(
            <SessionListView
                sessions={[{ id: "sess-1", agentKind: "codex", status: "running", workspacePath: "apps/api" }]}
                onCreate={onCreate}
                onSelect={onSelect}
            />,
        );

        expect(screen.getByText("codex")).toBeInTheDocument();
        expect(screen.getByText("running")).toBeInTheDocument();
        expect(screen.getByText("apps/api")).toBeInTheDocument();

        fireEvent.click(screen.getByRole("button", { name: "New session" }));
        expect(onCreate).toHaveBeenCalledTimes(1);

        fireEvent.click(screen.getByRole("button", { name: "Open codex" }));
        expect(onSelect).toHaveBeenCalledWith("sess-1");
    });
});
