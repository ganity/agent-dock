import { useState } from "react";

export function LoginView(props: {
  loading: boolean;
  error: string | null;
  onSubmit: (credentials: { username: string; password: string }) => void;
}) {
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");

  return (
    <form
      className="panel stack"
      onSubmit={(event) => {
        event.preventDefault();
        props.onSubmit({ username, password });
      }}
    >
      <div className="stack">
        <h1>Agent Dock</h1>
        <p className="muted">Sign in to your local daemon with your username and password.</p>
      </div>
      <label className="field">
        <span>Username</span>
        <input
          aria-label="Username"
          className="input"
          value={username}
          onChange={(event) => setUsername(event.target.value)}
        />
      </label>
      <label className="field">
        <span>Password</span>
        <input
          aria-label="Password"
          className="input"
          type="password"
          value={password}
          onChange={(event) => setPassword(event.target.value)}
        />
      </label>
      <button className="button" type="submit" disabled={props.loading}>
        Sign in
      </button>
      {props.error ? <p>{props.error}</p> : null}
    </form>
  );
}
