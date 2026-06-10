import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { SessionListView } from "../SessionListView";

describe("SessionListView", () => {
    it("renders sessions and exposes the create action", () => {
        const onCreate = vi.fn();

        render(
            <SessionListView
                sessions={[{ id: "sess-1", agentKind: "placeholder" }]}
                onCreate={onCreate}
            />,
        );

        expect(screen.getByText("placeholder")).toBeInTheDocument();

        fireEvent.click(screen.getByRole("button", { name: "New session" }));
        expect(onCreate).toHaveBeenCalledTimes(1);
    });
});
