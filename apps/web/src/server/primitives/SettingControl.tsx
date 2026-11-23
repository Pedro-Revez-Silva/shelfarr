import { useId, useRef, useState, type ReactNode } from "react";
import type { FieldOption, SettingField } from "../contract";
import { moveItem, type DraftValue } from "../draft";
import { SecretField } from "./SecretField";

export type LibraryChoice = { id: string; name: string; media_type: string };

export type ControlProps = {
  field: SettingField;
  value: DraftValue;
  onChange: (value: DraftValue) => void;
  error?: string | undefined;
  libraries?: LibraryChoice[] | null | undefined;
};

export function controlId(field: SettingField, scope: string): string {
  return `${scope}-${field.key}`;
}

function describedBy(...ids: (string | false | undefined)[]): string | undefined {
  const text = ids.filter(Boolean).join(" ");
  return text || undefined;
}

function rangeHint(field: SettingField): string | null {
  if (field.min !== undefined && field.max !== undefined) return `${field.min} to ${field.max}.`;
  if (field.min !== undefined) return `At least ${field.min}.`;
  return null;
}

function defaultHint(field: SettingField): string | null {
  const value = field.default;
  if (value === undefined || value === null || field.input === "toggle") return null;
  if (Array.isArray(value)) return null;
  const option = field.options?.find((entry) => entry.value === String(value));
  return `Default: ${option?.label ?? String(value)}.`;
}

export function sentences(...parts: (string | null | undefined)[]): string {
  return parts
    .map((part) => part?.trim())
    .filter((part): part is string => Boolean(part))
    .map((part) => (/[.!?)]$/.test(part) ? part : `${part}.`))
    .join(" ");
}

function Hint({ id, field, extra }: { id: string; field: SettingField; extra?: ReactNode }) {
  const parts = sentences(field.description, rangeHint(field), defaultHint(field));
  return (
    <p id={id} className="field-hint">
      {parts}
      {extra}
    </p>
  );
}

function FieldError({ id, error }: { id: string; error: string | undefined }) {
  if (!error) return null;
  return (
    <p id={id} className="field-error">
      <span aria-hidden="true">⚠ </span>
      {error}
    </p>
  );
}

function Warning({ field }: { field: SettingField }) {
  if (!field.warning) return null;
  return (
    <p className="field-warning">
      <span aria-hidden="true">⚠ </span>
      {field.warning}
    </p>
  );
}

export function SettingControl({ scope, ...props }: ControlProps & { scope: string }) {
  const { field } = props;
  if (field.managed_by !== undefined) return <ManagedField field={field} scope={scope} />;
  switch (field.input) {
    case "toggle":
      return <ToggleField {...props} scope={scope} />;
    case "secret":
      return <SecretField {...props} scope={scope} />;
    case "choice":
      return <ChoiceField {...props} scope={scope} />;
    case "order":
      return <OrderField {...props} scope={scope} />;
    case "events":
      return <CheckboxGroupField {...props} scope={scope} options={field.options ?? []} />;
    case "libraries":
      return props.libraries && props.libraries.length > 0 ? (
        <CheckboxGroupField {...props} scope={scope} options={libraryOptions(props.libraries, props.value)} />
      ) : (
        <TextField {...props} value={Array.isArray(props.value) ? props.value.join(", ") : props.value} onChange={(text) => props.onChange(String(text).split(",").map((entry) => entry.trim()).filter(Boolean))} scope={scope} />
      );
    case "library":
      return props.libraries && props.libraries.length > 0 ? <LibrarySelect {...props} libraries={props.libraries} scope={scope} /> : <TextField {...props} scope={scope} />;
    case "url_list":
      return <TextField {...props} scope={scope} multiline />;
    default:
      return <TextField {...props} scope={scope} />;
  }
}

function libraryOptions(libraries: LibraryChoice[], value: DraftValue): FieldOption[] {
  const options = libraries.map((library) => ({ value: library.id, label: `${library.name} (${library.media_type})` }));
  const chosen = Array.isArray(value) ? value : [];
  const missing = chosen.filter((id) => !libraries.some((library) => library.id === id)).map((id) => ({ value: id, label: `${id} (unavailable)` }));
  return [...options, ...missing];
}

function ManagedField({ field, scope }: { field: SettingField; scope: string }) {
  const id = controlId(field, scope);
  const shown = field.input === "secret" ? (field.configured ? "A value is set" : "Not set") : displayValue(field);
  return (
    <div className="field field--managed">
      <span className="field-label" id={`${id}-label`}>
        {field.label}
      </span>
      <p className="managed-value" aria-labelledby={`${id}-label`}>
        <span className="managed-text">{shown}</span>
        <span className="managed-source">
          <span aria-hidden="true">🔒 </span>Set by <code>{field.managed_by}</code> on the server. Change it there.
        </span>
      </p>
      <p className="field-hint">{sentences(field.description)}</p>
    </div>
  );
}

function displayValue(field: SettingField): string {
  const value = field.value;
  if (value === null || value === "" || (Array.isArray(value) && value.length === 0)) return "Not set";
  if (typeof value === "boolean") return value ? "On" : "Off";
  if (Array.isArray(value)) return value.join(", ");
  const option = field.options?.find((entry) => entry.value === String(value));
  return option?.label ?? String(value);
}

function ToggleField({ field, value, onChange, error, scope }: ControlProps & { scope: string }) {
  const id = controlId(field, scope);
  return (
    <div className="check-field setting-toggle">
      <input
        id={id}
        name={field.key}
        type="checkbox"
        checked={value === true}
        aria-invalid={error ? true : undefined}
        aria-describedby={describedBy(`${id}-hint`, error && `${id}-error`)}
        onChange={(event) => onChange(event.target.checked)}
      />
      <label htmlFor={id}>{field.label}</label>
      <div className="setting-toggle-text">
        <Hint id={`${id}-hint`} field={field} />
        <Warning field={field} />
        <FieldError id={`${id}-error`} error={error} />
      </div>
    </div>
  );
}

const IDENTIFIER_INPUTS = new Set(["url", "code", "country", "url_list", "library", "libraries", "list"]);

function TextField({ field, value, onChange, error, scope, multiline = false }: Omit<ControlProps, "onChange"> & { onChange: (value: string) => void; scope: string; multiline?: boolean }) {
  const id = controlId(field, scope);
  const text = Array.isArray(value) ? value.join(", ") : String(value);
  const common = {
    id,
    name: field.key,
    value: text,
    placeholder: field.placeholder,
    "aria-invalid": error ? true : undefined,
    "aria-describedby": describedBy(`${id}-hint`, error && `${id}-error`),
    spellCheck: IDENTIFIER_INPUTS.has(field.input) ? false : undefined,
    autoCapitalize: IDENTIFIER_INPUTS.has(field.input) ? "none" : undefined,
    autoCorrect: IDENTIFIER_INPUTS.has(field.input) ? "off" : undefined,
    autoComplete: "off",
  };
  return (
    <div className="field">
      <label htmlFor={id}>{field.label}</label>
      {multiline ? (
        <textarea {...common} rows={Math.min(8, Math.max(3, text.split("\n").length + 1))} onChange={(event) => onChange(event.target.value)} />
      ) : (
        <input
          {...common}
          type={field.input === "url" ? "url" : "text"}
          inputMode={field.input === "number" ? "numeric" : field.input === "url" ? "url" : undefined}
          className={field.input === "code" ? "code-input" : field.input === "number" ? "count-input" : field.input === "country" ? "country-input" : undefined}
          maxLength={field.input === "country" ? 2 : undefined}
          onChange={(event) => onChange(field.input === "country" ? event.target.value.toUpperCase() : event.target.value)}
        />
      )}
      <Hint id={`${id}-hint`} field={field} extra={multiline ? " One address per line." : field.input === "list" ? " Separate values with commas." : null} />
      <Warning field={field} />
      <FieldError id={`${id}-error`} error={error} />
    </div>
  );
}

function ChoiceField({ field, value, onChange, error, scope }: ControlProps & { scope: string }) {
  const id = controlId(field, scope);
  const options = field.options ?? [];
  const current = String(value);
  const known = options.some((option) => option.value === current);
  return (
    <fieldset className="field choice-field" aria-describedby={describedBy(`${id}-hint`, error && `${id}-error`)} aria-invalid={error ? true : undefined}>
      <legend>{field.label}</legend>
      <Hint id={`${id}-hint`} field={field} extra={!known && current !== "" ? ` The saved value "${current}" is not one of these choices.` : null} />
      <div className="choice-options">
        {options.map((option) => {
          const optionId = `${id}-${option.value}`;
          return (
            <div key={option.value} className="choice-option">
              <input id={optionId} type="radio" name={`${scope}-${field.key}`} value={option.value} checked={current === option.value} onChange={() => onChange(option.value)} aria-describedby={option.description ? `${optionId}-hint` : undefined} />
              <label htmlFor={optionId}>{option.label}</label>
              {option.description ? (
                <p id={`${optionId}-hint`} className="field-hint">
                  {option.description}
                </p>
              ) : null}
            </div>
          );
        })}
      </div>
      <Warning field={field} />
      <FieldError id={`${id}-error`} error={error} />
    </fieldset>
  );
}

function CheckboxGroupField({ field, value, onChange, error, scope, options }: ControlProps & { scope: string; options: FieldOption[] }) {
  const id = controlId(field, scope);
  const chosen = Array.isArray(value) ? value : [];
  const toggle = (option: string, checked: boolean) => {
    const next = checked ? [...chosen, option] : chosen.filter((entry) => entry !== option);
    onChange(options.map((entry) => entry.value).filter((entry) => next.includes(entry)));
  };
  return (
    <fieldset className="field choice-field" aria-describedby={describedBy(`${id}-hint`, error && `${id}-error`)}>
      <legend>{field.label}</legend>
      <Hint id={`${id}-hint`} field={field} />
      <div className="choice-options">
        {options.map((option) => {
          const optionId = `${id}-${option.value}`;
          return (
            <div key={option.value} className="choice-option">
              <input id={optionId} type="checkbox" checked={chosen.includes(option.value)} onChange={(event) => toggle(option.value, event.target.checked)} />
              <label htmlFor={optionId}>{option.label}</label>
            </div>
          );
        })}
      </div>
      <FieldError id={`${id}-error`} error={error} />
    </fieldset>
  );
}

function LibrarySelect({ field, value, onChange, error, scope, libraries }: ControlProps & { scope: string; libraries: LibraryChoice[] }) {
  const id = controlId(field, scope);
  const current = String(value);
  const missing = current !== "" && !libraries.some((library) => library.id === current);
  return (
    <div className="field">
      <label htmlFor={id}>{field.label}</label>
      <select id={id} name={field.key} value={current} aria-invalid={error ? true : undefined} aria-describedby={describedBy(`${id}-hint`, error && `${id}-error`)} onChange={(event) => onChange(event.target.value)}>
        <option value="">{field.placeholder ?? "Choose a library"}</option>
        {libraries.map((library) => (
          <option key={library.id} value={library.id}>
            {library.name} ({library.media_type})
          </option>
        ))}
        {missing ? <option value={current}>{current} (unavailable)</option> : null}
      </select>
      <Hint id={`${id}-hint`} field={field} />
      <FieldError id={`${id}-error`} error={error} />
    </div>
  );
}

function OrderField({ field, value, onChange, error, scope }: ControlProps & { scope: string }) {
  const id = controlId(field, scope);
  const order = Array.isArray(value) ? value : [];
  const labels = new Map((field.options ?? []).map((option) => [option.value, option]));
  const [announcement, setAnnouncement] = useState("");
  const buttons = useRef(new Map<string, HTMLButtonElement>());
  const move = (index: number, offset: -1 | 1) => {
    const next = moveItem(order, index, offset);
    const item = order[index];
    if (next === order || item === undefined) return;
    onChange(next);
    const name = labels.get(item)?.label ?? item;
    setAnnouncement(`${name} moved to position ${index + offset + 1} of ${order.length}.`);
    const target = `${item}-${offset}`;
    requestAnimationFrame(() => {
      const button = buttons.current.get(target);
      if (button && !button.disabled) button.focus();
      else buttons.current.get(`${item}-${-offset}`)?.focus();
    });
  };
  return (
    <fieldset className="field order-field" aria-describedby={describedBy(`${id}-hint`, error && `${id}-error`)}>
      <legend>{field.label}</legend>
      <Hint id={`${id}-hint`} field={field} extra=" Most preferred first." />
      <ol className="order-list">
        {order.map((item, index) => {
          const option = labels.get(item);
          const name = option?.label ?? item;
          return (
            <li key={item} className="order-item">
              <span className="order-rank" aria-hidden="true">
                {index + 1}
              </span>
              <span className="order-text">
                <span className="order-name">{name}</span>
                {option?.description ? <span className="field-hint">{option.description}</span> : null}
              </span>
              <span className="order-buttons">
                <button
                  ref={(element) => void (element ? buttons.current.set(`${item}--1`, element) : buttons.current.delete(`${item}--1`))}
                  type="button"
                  className="button button--subtle order-button"
                  disabled={index === 0}
                  onClick={() => move(index, -1)}
                  aria-label={`Move ${name} up`}
                >
                  ↑
                </button>
                <button
                  ref={(element) => void (element ? buttons.current.set(`${item}-1`, element) : buttons.current.delete(`${item}-1`))}
                  type="button"
                  className="button button--subtle order-button"
                  disabled={index === order.length - 1}
                  onClick={() => move(index, 1)}
                  aria-label={`Move ${name} down`}
                >
                  ↓
                </button>
              </span>
            </li>
          );
        })}
      </ol>
      <p className="sr-only" role="status">
        {announcement}
      </p>
      <FieldError id={`${id}-error`} error={error} />
    </fieldset>
  );
}

export function useScope(): string {
  return useId().replace(/[^a-zA-Z0-9_-]/g, "");
}
