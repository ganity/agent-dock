import { useState } from "react";
import { LoginView } from "./components/LoginView";
import { SessionListView } from "./components/SessionListView";
import type { SessionSummary } from "./types";

export default function App() {
  const [authenticated, setAuthenticated] = useState(false);
  const [sessions] = useState<SessionSummary[]>([]);

  return (
    <main className="shell">
      {authenticated ? (
        <SessionListView sessions={sessions} onCreate={() => {}} />
      ) : (
        <LoginView loading={false} error={null} onSubmit={() => setAuthenticated(true)} />
      )}
    </main>
  );
}
