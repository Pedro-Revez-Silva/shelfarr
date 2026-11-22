import { useEffect, useRef, useState } from "react";
import { sentences, type ControlProps } from "./SettingControl";

export function SecretField({ field, value, onChange, error, scope }: ControlProps & { scope: string }) {
  const id = `${scope}-${field.key}`;
  const text = typeof value === "string" ? value : "";
  const [replacing, setReplacing] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const replace = useRef<HTMLButtonElement>(null);
  const opened = useRef(false);
  const open = !field.configured || replacing || text !== "" || Boolean(error);
  useEffect(() => {
    if (replacing && !opened.current) input.current?.focus();
    opened.current = replacing;
  }, [replacing]);
  const keep = () => {
    onChange("");
    setReplacing(false);
    requestAnimationFrame(() => replace.current?.focus());
  };
  const hint = field.configured ? "A value is saved and is never shown. Leave this blank to keep it." : "Nothing is saved yet.";
  return (
    <div className="field secret-field">
      <span className="field-label-row">
        <label htmlFor={open ? id : undefined} id={`${id}-label`}>
          {field.label}
        </label>
        {field.configured ? <span className="badge secret-saved">Saved</span> : null}
      </span>
      {open ? (
        <span className="password-row">
          <input
            ref={input}
            id={id}
            name={field.key}
            type="password"
            value={text}
            autoComplete="new-password"
            spellCheck={false}
            placeholder={field.placeholder}
            aria-invalid={error ? true : undefined}
            aria-describedby={[`${id}-hint`, error ? `${id}-error` : ""].filter(Boolean).join(" ")}
            onChange={(event) => onChange(event.target.value)}
          />
          {field.configured ? (
            <button type="button" className="button button--subtle button--icon" onClick={keep}>
              Keep saved
            </button>
          ) : null}
        </span>
      ) : (
        <span className="password-row">
          <button ref={replace} type="button" className="button" aria-describedby={`${id}-label ${id}-hint`} onClick={() => setReplacing(true)}>
            Replace
          </button>
        </span>
      )}
      <p id={`${id}-hint`} className="field-hint">
        {sentences(field.description, hint)}
      </p>
      {error ? (
        <p id={`${id}-error`} className="field-error">
          <span aria-hidden="true">⚠ </span>
          {error}
        </p>
      ) : null}
    </div>
  );
}
