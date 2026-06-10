import { useState } from "react";

export function Composer(props: { onSend: (message: string) => void }) {
  const [value, setValue] = useState("");

  return (
    <form
      className="panel stack"
      onSubmit={(event) => {
        event.preventDefault();
        if (value.trim().length === 0) return;
        props.onSend(value);
        setValue("");
      }}
    >
      <label className="field">
        <span>Message</span>
        <textarea
          aria-label="Message"
          className="input"
          value={value}
          onChange={(event) => setValue(event.target.value)}
        />
      </label>
      <button className="button" type="submit">
        Send
      </button>
    </form>
  );
}
