import { useState } from "react";
import { createSession, listSessions, login } from "./api";
import { CreateSessionView } from "./components/CreateSessionView";
import { LoginView } from "./components/LoginView";
import { SessionListView } from "./components/SessionListView";
import type { SessionSummary } from "./types";

export default function App() {
  const [authenticated, setAuthenticated] = useState(false);
  const [sessions, setSessions] = useState<SessionSummary[]>([]);
  const [loginError, setLoginError] = useState<string | null>(null);

  async function refreshSessions(): Promise<void> {
    setSessions(await listSessions());
  }

  return (
    <main className="shell">
      {authenticated ? (
        <section className="stack">
          <SessionListView sessions={sessions} onCreate={() => {}} />
          <CreateSessionView
            onSubmit={(input) => {
              void (async () => {
                const created = await createSession(input);
                setSessions((current) => [...current, created]);
              })();
            }}
          />
        </section>
      ) : (
        <LoginView
          loading={false}
          error={loginError}
          onSubmit={(pin) => {
            void (async () => {
              try {
                await login(pin);
                await refreshSessions();
                setAuthenticated(true);
                setLoginError(null);
              } catch (error) {
                setLoginError(error instanceof Error ? error.message : String(error));
              }
            })();
          }}
        />
      )}
    </main>
  );
}
