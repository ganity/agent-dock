import { useState } from "react";
import { createSession, fetchSessionSnapshot, listSessions, login } from "./api";
import { CreateSessionView } from "./components/CreateSessionView";
import { LoginView } from "./components/LoginView";
import { SessionDetailView } from "./components/SessionDetailView";
import { SessionListView } from "./components/SessionListView";
import type { SessionDetail, SessionSummary } from "./types";

export default function App() {
  const [authenticated, setAuthenticated] = useState(false);
  const [sessions, setSessions] = useState<SessionSummary[]>([]);
  const [selectedSession, setSelectedSession] = useState<SessionDetail | null>(null);
  const [loginError, setLoginError] = useState<string | null>(null);

  async function refreshSessions(): Promise<void> {
    setSessions(await listSessions());
  }

  return (
    <main className="shell">
      {authenticated ? (
        selectedSession ? (
          <SessionDetailView
            session={selectedSession}
            onBack={() => setSelectedSession(null)}
            onSend={() => {}}
          />
        ) : (
          <section className="stack">
            <SessionListView
              sessions={sessions}
              onCreate={() => {}}
              onSelect={(sessionId) => {
                void (async () => {
                  const detail = await fetchSessionSnapshot(sessionId);
                  setSelectedSession(detail);
                })();
              }}
            />
            <CreateSessionView
              onSubmit={(input) => {
                void (async () => {
                  const created = await createSession(input);
                  setSessions((current) => [...current, created]);
                  setSelectedSession(created);
                })();
              }}
            />
          </section>
        )
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
