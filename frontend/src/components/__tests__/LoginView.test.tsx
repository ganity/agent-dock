import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { LoginView } from "../LoginView";

describe("LoginView", () => {
    it("submits the pin value", () => {
        const onSubmit = vi.fn();

        render(<LoginView loading={false} error={null} onSubmit={onSubmit} />);

        fireEvent.change(screen.getByLabelText("PIN"), { target: { value: "1234" } });
        fireEvent.click(screen.getByRole("button", { name: "Unlock" }));

        expect(onSubmit).toHaveBeenCalledWith("1234");
    });
});
