import { useState } from "react";

export function LoginView(props: {
  loading: boolean;
  error: string | null;
  onSubmit: (pin: string) => void;
}) {
  const [pin, setPin] = useState("");

  return (
    <form
      className="panel stack"
      onSubmit={(event) => {
        event.preventDefault();
        props.onSubmit(pin);
      }}
    >
      <div className="stack">
        <h1>Agent Workspace</h1>
        <p className="muted">Unlock your local daemon with the device PIN.</p>
      </div>
      <label className="field">
        <span>PIN</span>
        <input
          aria-label="PIN"
          className="input"
          value={pin}
          onChange={(event) => setPin(event.target.value)}
        />
      </label>
      <button className="button" type="submit" disabled={props.loading}>
        Unlock
      </button>
      {props.error ? <p>{props.error}</p> : null}
    </form>
  );
}
