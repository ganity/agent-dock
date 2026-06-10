import type { CreateSessionInput } from "../types";

export function CreateSessionView(props: {
  onSubmit: (input: CreateSessionInput) => void;
}) {
  return (
    <button
      className="button"
      type="button"
      onClick={() =>
        props.onSubmit({
          rootId: "workspace",
          path: "repo",
          agentKind: "claude",
        })
      }
    >
      Create Claude session
    </button>
  );
}
