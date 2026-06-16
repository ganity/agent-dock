import { useEffect, useRef, type ReactNode } from "react";

const FOCUSABLE_SELECTOR =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

function createId(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}

export function SessionModal(props: {
  title: string;
  description: string;
  onClose: () => void;
  children: ReactNode;
}) {
  const titleId = `${createId(props.title)}-title`;
  const descriptionId = `${createId(props.title)}-description`;
  const dialogRef = useRef<HTMLElement | null>(null);
  const onCloseRef = useRef(props.onClose);
  const previousActiveElementRef = useRef<HTMLElement | null>(null);

  useEffect(() => {
    onCloseRef.current = props.onClose;
  }, [props.onClose]);

  useEffect(() => {
    const dialog = dialogRef.current;
    previousActiveElementRef.current =
      document.activeElement instanceof HTMLElement ? document.activeElement : null;

    function getFocusableElements(): HTMLElement[] {
      if (!dialog) {
        return [];
      }

      return Array.from(dialog.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR)).filter(
        (element) => !element.hasAttribute("disabled") && element.getAttribute("aria-hidden") !== "true",
      );
    }

    const focusableElements = getFocusableElements();
    const initialFocusTarget = focusableElements[0] ?? dialog;
    initialFocusTarget.focus();

    function handleKeyDown(event: KeyboardEvent): void {
      if (event.key === "Escape") {
        onCloseRef.current();
        return;
      }

      if (event.key !== "Tab") {
        return;
      }

      const focusable = getFocusableElements();
      if (focusable.length === 0) {
        event.preventDefault();
        dialog?.focus();
        return;
      }

      const firstFocusable = focusable[0];
      const lastFocusable = focusable[focusable.length - 1];
      const activeElement = document.activeElement instanceof HTMLElement ? document.activeElement : null;

      if (event.shiftKey) {
        if (activeElement === firstFocusable || activeElement === dialog) {
          event.preventDefault();
          lastFocusable.focus();
        }
        return;
      }

      if (activeElement === lastFocusable) {
        event.preventDefault();
        firstFocusable.focus();
      }
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => {
      window.removeEventListener("keydown", handleKeyDown);
      previousActiveElementRef.current?.focus();
    };
  }, []);

  return (
    <div className="session-modal-backdrop" onClick={props.onClose}>
      <section
        aria-describedby={descriptionId}
        aria-labelledby={titleId}
        aria-modal="true"
        className="session-modal panel stack"
        onClick={(event) => event.stopPropagation()}
        ref={dialogRef}
        role="dialog"
        tabIndex={-1}
      >
        <header className="session-modal-header">
          <div className="stack">
            <h2 id={titleId}>{props.title}</h2>
            <p id={descriptionId}>{props.description}</p>
          </div>
        </header>
        {props.children}
      </section>
    </div>
  );
}
