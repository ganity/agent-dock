import { useEffect, useState } from "react";
import {
  attachSession,
  connectSessionEvents,
  connectVoiceInput,
  createSession,
  createUser,
  deleteUser,
  deleteSession,
  fetchSessionSnapshot,
  listDirectories,
  listResumeCandidates,
  listRoots,
  listSessions,
  listUsers,
  login,
  resetUserPassword,
  resumeSession,
  restoreSession,
  sendSessionMessage,
  uploadSessionAttachment,
} from "./api";
import { AttachSessionView } from "./components/AttachSessionView";
import { CreateSessionView } from "./components/CreateSessionView";
import { LoginView } from "./components/LoginView";
import { SessionDetailView } from "./components/SessionDetailView";
import { SessionListView } from "./components/SessionListView";
import { getSessionTitle } from "./sessionDisplay";
import type { AdminUser, CurrentUser, SessionDetail, SessionEvent, SessionSummary, WorkspaceRoot } from "./types";

export default function App() {
  const [authState, setAuthState] = useState<"checking" | "authenticated" | "anonymous">("checking");
  const [currentUser, setCurrentUser] = useState<CurrentUser | null>(null);
  const [roots, setRoots] = useState<WorkspaceRoot[]>([]);
  const [sessions, setSessions] = useState<SessionSummary[]>([]);
  const [users, setUsers] = useState<AdminUser[]>([]);
  const [selectedSession, setSelectedSession] = useState<SessionDetail | null>(null);
  const [loadingHistory, setLoadingHistory] = useState(false);
  const [loginError, setLoginError] = useState<string | null>(null);
  const [showCreateForm, setShowCreateForm] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);
  const [showAttachForm, setShowAttachForm] = useState(false);
  const [attachError, setAttachError] = useState<string | null>(null);
  const [deletingSessionId, setDeletingSessionId] = useState<string | null>(null);

  function getErrorMessage(error: unknown): string {
    return error instanceof Error ? error.message : String(error);
  }

  async function refreshHomeData(user: CurrentUser | null = currentUser): Promise<void> {
    const [nextRoots, nextSessions, nextUsers] = await Promise.all([
      listRoots(),
      listSessions(),
      user?.isAdmin ? listUsers() : Promise.resolve([]),
    ]);
    setRoots(nextRoots);
    setSessions(nextSessions);
    setUsers(nextUsers);
  }

  function refreshHomeDataInBackground(user: CurrentUser | null = currentUser): void {
    void refreshHomeData(user).catch((error) => {
      window.alert(getErrorMessage(error));
    });
  }

  useEffect(() => {
    void (async () => {
      try {
        const user = await restoreSession();
        setCurrentUser(user);
        await refreshHomeData(user);
        setAuthState("authenticated");
        setLoginError(null);
      } catch {
        setCurrentUser(null);
        setRoots([]);
        setSessions([]);
        setUsers([]);
        setAuthState("anonymous");
      }
    })();
  }, []);

  useEffect(() => {
    if (!selectedSession) return;

    const lastEventId = selectedSession.events.at(-1)?.id ?? 0;
    const socket = connectSessionEvents(selectedSession.id, lastEventId);
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
      {authState === "checking" ? null : authState === "authenticated" ? (
        selectedSession ? (
          <SessionDetailView
            session={selectedSession}
            onBack={() => {
              setSelectedSession(null);
              refreshHomeDataInBackground();
            }}
            onSend={(message, imagePaths) => {
              void sendSessionMessage(selectedSession.id, message, imagePaths);
            }}
            onUploadImage={(file) => {
              return uploadSessionAttachment(selectedSession.id, file);
            }}
            onConnectVoiceInput={() => connectVoiceInput()}
            onLoadOlder={() => {
              void (async () => {
                if (loadingHistory) {
                  return;
                }

                const oldestEventId = selectedSession.events[0]?.id;
                if (!selectedSession.hasMoreHistory || !oldestEventId) {
                  return;
                }

                setLoadingHistory(true);
                try {
                  const older = await fetchSessionSnapshot(selectedSession.id, {
                    limit: 50,
                    before: oldestEventId,
                  });
                  setSelectedSession((current) => {
                    if (!current || current.id !== selectedSession.id) {
                      return current;
                    }

                    const mergedEvents = [
                      ...older.events,
                      ...current.events.filter(
                        (event) => !older.events.some((olderEvent) => olderEvent.id === event.id),
                      ),
                    ];

                    return {
                      ...current,
                      hasMoreHistory: older.hasMoreHistory,
                      events: mergedEvents,
                    };
                  });
                } finally {
                  setLoadingHistory(false);
                }
              })();
            }}
            loadingHistory={loadingHistory}
          />
        ) : (
          <section className="stack">
            <SessionListView
              currentUser={currentUser}
              hasRoots={roots.length > 0}
              sessions={sessions}
              users={users}
              onCreateUser={async (input) => {
                await createUser(input);
                setUsers(await listUsers());
              }}
              onResetPassword={async (userId, password) => {
                await resetUserPassword(userId, password);
              }}
              onDeleteUser={async (userId) => {
                await deleteUser(userId);
                setUsers(await listUsers());
              }}
              onCreate={() => {
                setShowAttachForm(false);
                setAttachError(null);
                setShowCreateForm(true);
                setCreateError(null);
                refreshHomeDataInBackground();
              }}
              onAttach={() => {
                setShowCreateForm(false);
                setCreateError(null);
                setShowAttachForm(true);
                setAttachError(null);
                refreshHomeDataInBackground();
              }}
              onSelect={(sessionId) => {
                void (async () => {
                  const session = sessions.find((item) => item.id === sessionId);
                  const detail =
                    session?.status === "suspended"
                      ? await resumeSession(sessionId)
                      : await fetchSessionSnapshot(sessionId, { limit: 50 });
                  setLoadingHistory(false);
                  setSelectedSession(detail);
                })();
              }}
              onDelete={(sessionId) => {
                const session = sessions.find((item) => item.id === sessionId);
                if (!session) {
                  return;
                }

                const title = getSessionTitle(session);
                if (!window.confirm(`Delete ${title}? This stops the session and removes its data.`)) {
                  return;
                }

                setDeletingSessionId(sessionId);
                void (async () => {
                  try {
                    await deleteSession(sessionId);
                    setSessions((current) => current.filter((item) => item.id !== sessionId));
                    setSelectedSession((current) => (current?.id === sessionId ? null : current));
                  } catch (error) {
                    window.alert(getErrorMessage(error));
                  } finally {
                    setDeletingSessionId((current) => (current === sessionId ? null : current));
                  }
                })();
              }}
              deletingSessionId={deletingSessionId}
            />
            {showCreateForm ? (
              <CreateSessionView
                roots={roots}
                error={createError}
                loadDirectories={listDirectories}
                onCancel={() => {
                  setShowCreateForm(false);
                  setCreateError(null);
                }}
                onSubmit={(input) => {
                  void (async () => {
                    try {
                      const created = await createSession(input);
                      setSessions((current) => [...current, created]);
                      setShowCreateForm(false);
                      setCreateError(null);
                      setSelectedSession(created);
                    } catch (error) {
                      setCreateError(getErrorMessage(error));
                    }
                  })();
                }}
              />
            ) : null}
            {showAttachForm ? (
              <AttachSessionView
                roots={roots}
                error={attachError}
                loadDirectories={listDirectories}
                loadResumeCandidates={listResumeCandidates}
                onCancel={() => {
                  setShowAttachForm(false);
                  setAttachError(null);
                }}
                onSubmit={(input) => {
                  void (async () => {
                    try {
                      const attached = await attachSession(input);
                      setSessions((current) => [...current, attached]);
                      setShowAttachForm(false);
                      setAttachError(null);
                      setSelectedSession(attached);
                    } catch (error) {
                      setAttachError(getErrorMessage(error));
                    }
                  })();
                }}
              />
            ) : null}
          </section>
        )
      ) : (
        <LoginView
          loading={false}
          error={loginError}
          onSubmit={({ username, password }) => {
            void (async () => {
              try {
                const user = await login(username, password);
                setCurrentUser(user);
                await refreshHomeData(user);
                setAuthState("authenticated");
                setLoginError(null);
              } catch (error) {
                setLoginError(getErrorMessage(error));
              }
            })();
          }}
        />
      )}
    </main>
  );
}
