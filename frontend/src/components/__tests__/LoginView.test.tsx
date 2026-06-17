import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { LoginView } from "../LoginView";

describe("LoginView", () => {
    it("submits the username and password values", () => {
        const onSubmit = vi.fn();

        render(<LoginView loading={false} error={null} onSubmit={onSubmit} />);

        fireEvent.change(screen.getByLabelText("Username"), { target: { value: "admin" } });
        fireEvent.change(screen.getByLabelText("Password"), { target: { value: "1234" } });
        fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

        expect(onSubmit).toHaveBeenCalledWith({ username: "admin", password: "1234" });
    });
});
