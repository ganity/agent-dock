import type { ReactNode } from "react";

type Block =
  | { kind: "code"; text: string }
  | { kind: "heading"; level: 2 | 3; text: string }
  | { kind: "ul"; items: string[] }
  | { kind: "ol"; items: string[] }
  | { kind: "paragraph"; text: string };

export function MarkdownContent(props: { text: string }) {
  const blocks = parseMarkdownBlocks(props.text);

  return (
    <div className="markdown-content">
      {blocks.map((block, index) => {
        if (block.kind === "code") {
          return (
            <pre key={index} className="markdown-code">
              <code>{block.text}</code>
            </pre>
          );
        }

        if (block.kind === "heading") {
          const HeadingTag = block.level === 2 ? "h2" : "h3";
          return <HeadingTag key={index}>{renderInline(block.text)}</HeadingTag>;
        }

        if (block.kind === "ul") {
          return (
            <ul key={index}>
              {block.items.map((item, itemIndex) => (
                <li key={itemIndex}>{renderInline(item)}</li>
              ))}
            </ul>
          );
        }

        if (block.kind === "ol") {
          return (
            <ol key={index}>
              {block.items.map((item, itemIndex) => (
                <li key={itemIndex}>{renderInline(item)}</li>
              ))}
            </ol>
          );
        }

        return <p key={index}>{renderInline(block.text)}</p>;
      })}
    </div>
  );
}

function parseMarkdownBlocks(text: string): Block[] {
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  const blocks: Block[] = [];
  let paragraph: string[] = [];
  let code: string[] | null = null;
  let unorderedItems: string[] = [];
  let orderedItems: string[] = [];

  const flushParagraph = () => {
    if (paragraph.length === 0) return;
    blocks.push({ kind: "paragraph", text: paragraph.join(" ") });
    paragraph = [];
  };

  const flushLists = () => {
    if (unorderedItems.length > 0) {
      blocks.push({ kind: "ul", items: unorderedItems });
      unorderedItems = [];
    }

    if (orderedItems.length > 0) {
      blocks.push({ kind: "ol", items: orderedItems });
      orderedItems = [];
    }
  };

  for (const line of lines) {
    if (/^```\w*\s*$/.test(line)) {
      if (code) {
        blocks.push({ kind: "code", text: code.join("\n") });
        code = null;
      } else {
        flushParagraph();
        flushLists();
        code = [];
      }
      continue;
    }

    if (code) {
      code.push(line);
      continue;
    }

    if (line.trim().length === 0) {
      flushParagraph();
      flushLists();
      continue;
    }

    const heading = line.match(/^(#{2,3})\s+(.+)$/);
    if (heading) {
      flushParagraph();
      flushLists();
      blocks.push({
        kind: "heading",
        level: heading[1].length === 2 ? 2 : 3,
        text: heading[2],
      });
      continue;
    }

    const unordered = line.match(/^\s*[-*]\s+(.+)$/);
    if (unordered) {
      flushParagraph();
      if (orderedItems.length > 0) flushLists();
      unorderedItems.push(unordered[1]);
      continue;
    }

    const ordered = line.match(/^\s*\d+\.\s+(.+)$/);
    if (ordered) {
      flushParagraph();
      if (unorderedItems.length > 0) flushLists();
      orderedItems.push(ordered[1]);
      continue;
    }

    flushLists();
    paragraph.push(line.trim());
  }

  if (code) {
    blocks.push({ kind: "code", text: code.join("\n") });
  }
  flushParagraph();
  flushLists();

  return blocks;
}

function renderInline(text: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  const pattern = /(`[^`]+`|\*\*[^*]+\*\*)/g;
  let cursor = 0;
  let match: RegExpExecArray | null;

  while ((match = pattern.exec(text)) !== null) {
    if (match.index > cursor) {
      nodes.push(text.slice(cursor, match.index));
    }

    const value = match[0];
    if (value.startsWith("`")) {
      nodes.push(<code key={nodes.length}>{value.slice(1, -1)}</code>);
    } else {
      nodes.push(<strong key={nodes.length}>{value.slice(2, -2)}</strong>);
    }

    cursor = match.index + value.length;
  }

  if (cursor < text.length) {
    nodes.push(text.slice(cursor));
  }

  return nodes;
}
