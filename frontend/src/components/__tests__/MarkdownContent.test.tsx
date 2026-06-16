import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { MarkdownContent } from "../MarkdownContent";

describe("MarkdownContent", () => {
  it("renders common assistant markdown as structured safe elements", () => {
    render(
      <MarkdownContent
        text={`## 问题与步骤概要

问题：**parse_received_data** 帧切割修复

- 修改 \`decode_status_response\`
- 修复 FrameCodec

\`\`\`python
def parse_received_data(buffer):
    return buffer
\`\`\``}
      />,
    );

    expect(screen.getByRole("heading", { level: 2, name: "问题与步骤概要" })).toBeInTheDocument();
    expect(screen.getByText("parse_received_data")).toBeInTheDocument();
    expect(screen.getByText("decode_status_response")).toBeInTheDocument();
    expect(screen.getByText("修改")).toBeInTheDocument();
    expect(screen.getByText(/def parse_received_data/).tagName).toBe("CODE");
  });

  it("does not inject raw html from assistant output", () => {
    render(<MarkdownContent text={'<img src=x onerror="alert(1)"> **safe**'} />);

    expect(document.querySelector("img")).toBeNull();
    expect(screen.getByText(/<img src=x/)).toBeInTheDocument();
    expect(screen.getByText("safe")).toBeInTheDocument();
  });
});
