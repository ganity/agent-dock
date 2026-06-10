import { useEffect, useState } from "react";
import {
  connectEventStream,
  createSession,
  fetchSessionSnapshot,
  listRoots,
  listSessions,
  login,
  sendSessionMessage,
} from "./api";
import { CreateSessionView } from "./components/CreateSessionView";
import { LoginView } from "./components/LoginView";
import { SessionDetailView } from "./components/SessionDetailView";
import { SessionListView } from "./components/SessionListView";
import type { SessionDetail, SessionEvent, SessionSummary, WorkspaceRoot } from "./types";

export default function App() {
  const [authenticated, setAuthenticated] = useState(false);
  const [roots, setRoots] = useState<WorkspaceRoot[]>([]);
  const [sessions, setSessions] = useState<SessionSummary[]>([]);
  const [selectedSession, setSelectedSession] = useState<SessionDetail | null>(null);
  const [loginError, setLoginError] = useState<string | null>(null);

  async function refreshSessions(): Promise<void> {
    setSessions(await listSessions());
  }

  async function refreshRoots(): Promise<void> {
    setRoots(await listRoots());
  }

  useEffect(() => {
    if (!selectedSession) return;

    const lastEventId = selectedSession.events.at(-1)?.id ?? 0;
    const socket = connectEventStream(selectedSession.id, lastEventId);
    socket.onmessage = (event) => {
      const nextEvent = JSON.parse(event.data) as SessionEvent;
      setSelectedSession((current) => {
        if (!current || current.id !== selectedSession.id) return current;
        if (current.events.some((item) => item.id === nextEvent.id)) return current;
        return {
          ...current,
          events: [...current.events, nextEvent],
        };
      });
    };

    return () => {
      socket.close();
    };
  }, [selectedSession]);

  return (
    <main className="shell">
      {authenticated ? (
        selectedSession ? (
          <SessionDetailView
            session={selectedSession}
            onBack={() => setSelectedSession(null)}
            onSend={(message) => {
              void sendSessionMessage(selectedSession.id, message);
            }}
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
              roots={roots}
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
                await refreshRoots();
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
