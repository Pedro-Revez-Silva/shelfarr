import { useEffect, useRef, useState } from "react";

export function RemoveZone({ label, confirmLabel, question, busy, onRemove }: { label: string; confirmLabel: string; question: string; busy?: boolean; onRemove: () => void }) {
  const [asking, setAsking] = useState(false);
  const confirm = useRef<HTMLButtonElement>(null);
  const start = useRef<HTMLButtonElement>(null);
  const wasAsking = useRef(false);
  useEffect(() => {
    if (asking) confirm.current?.focus();
    else if (wasAsking.current) start.current?.focus();
    wasAsking.current = asking;
  }, [asking]);
  if (!asking) {
    return (
      <button ref={start} type="button" className="button button--subtle button--danger" onClick={() => setAsking(true)}>
        {label}
      </button>
    );
  }
  return (
    <span className="remove-zone" role="group" aria-label={question}>
      <span className="remove-zone-question">{question}</span>
      <button ref={confirm} type="button" className="button button--danger" disabled={busy} aria-busy={busy} onClick={onRemove}>
        {confirmLabel}
      </button>
      <button type="button" className="button button--subtle" onClick={() => setAsking(false)}>
        Keep it
      </button>
    </span>
  );
}
