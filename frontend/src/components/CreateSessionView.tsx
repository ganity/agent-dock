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
          agentKind: "placeholder",
        })
      }
    >
      Create placeholder session
    </button>
  );
}
