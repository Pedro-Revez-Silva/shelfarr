import { Link, useBlocker, useNavigate, useParams } from "@tanstack/react-router";
import { useCallback, useEffect, useId, useRef, useState, type FormEvent, type ReactNode } from "react";
import { failureKind, isApiError, unconfirmed } from "../../api/errors";
import { fieldMessage } from "../../components/accountFields";
import { EmptyState, ErrorPanel, Loading } from "../../components/States";
import { useSession } from "../../queries";
import { useServices } from "../../services";
import { useDocumentTitle } from "../../title";
import { CardActions, RemoveZone, SettingsCard } from "../primitives";
import { useIsAdministrator } from "../queries";
import { AdministratorsOnly, LeaveDialog, NotInThisRuntime } from "../ServerCategoryPage";
import { ServerShell } from "../ServerShell";
import type { FieldErrors, PersonAnswer, ProfileValues } from "./api";
import { personRoles, type PersonEnvelope, type PersonRecord, type PersonRole } from "./contract";
import { AddedOn, PEOPLE_ARRIVAL, ROLE_LABELS } from "./PeopleCard";
import { announceArrival, isRemovedPerson, useAddPerson, useArrival, usePeopleWriting, usePerson, useRemovePerson, useSaveProfile, useSetPassword } from "./queries";
import "./people.css";

type Said = { tone: "success" | "error"; text: string; serial: number };

const ROLE_HINTS: Record<PersonRole, string> = {
  member: "Requests and reads books. What else members may do is set under What members can do.",
  administrator: "Also manages every request, the server settings and the people on this server.",
};

const USERNAME_MESSAGES: Record<string, string> = {
  "can't be blank": "Enter a username.",
  "has already been taken": "Someone on this server already has this username. Choose another.",
  "only allows lowercase letters, numbers, and underscores": "Use only lowercase letters, numbers and underscores.",
};

const PROFILE_FIELDS = ["name", "username", "role"] as const;
const PASSWORD_FIELDS = ["password", "password_confirmation"] as const;

function messageFor(field: string, messages: readonly string[]): string {
  if (field === "username") return messages.map((message) => USERNAME_MESSAGES[message] ?? `Username ${message}.`).join(" ");
  if (field === "password" && messages.includes("can't be blank")) return "Enter a password.";
  if (field === "password_confirmation") return messages.map((message) => (message === "doesn't match Password" ? "This does not match the password." : `Confirmation ${message}.`)).join(" ");
  return fieldMessage(field, messages);
}

export function peopleFailureText(error: unknown): string {
  if (unconfirmed(error)) return "Shelfarr could not confirm whether this was saved. Reload the page to see what the server has, and try again if needed.";
  if (!isApiError(error)) return "Shelfarr could not confirm whether this was saved. Reload the page to check.";
  if (error.code === "user_not_found") return "This person is no longer on this server. Nothing was changed.";
  switch (error.kind) {
    case "csrf":
      return "This page was out of date. Nothing was changed; try again.";
    case "not_found":
      return "Only administrators can manage people. Nothing was changed.";
    default:
      return "The server did not accept this. Nothing was changed; reload the page and try again.";
  }
}

function useSay() {
  const [said, setSaid] = useState<Said | null>(null);
  const serial = useRef(0);
  const say = (tone: Said["tone"], text: string) => {
    serial.current += 1;
    setSaid({ tone, text, serial: serial.current });
  };
  return { said, say, clear: () => setSaid(null) };
}

function Status({ said, extra }: { said: Said | null; extra?: ReactNode }) {
  return (
    <div className="settings-card-status" role="status">
      {said ? (
        <p key={said.serial} className={said.tone === "error" ? "form-error" : "form-success"}>
          {said.text}
        </p>
      ) : null}
      {extra}
    </div>
  );
}

function describedBy(...ids: (string | false | undefined)[]): string | undefined {
  const text = ids.filter(Boolean).join(" ");
  return text || undefined;
}

function FieldError({ id, field, errors }: { id: string; field: string; errors: FieldErrors }) {
  const messages = errors[field];
  if (!messages?.length) return null;
  return (
    <p id={id} className="field-error">
      <span aria-hidden="true">⚠ </span>
      {messageFor(field, messages)}
    </p>
  );
}

function TextInput({ scope, field, label, hint, errors, locked = false, ...input }: { scope: string; field: "name" | "username"; label: string; hint?: string; errors: FieldErrors; locked?: boolean; value: string; onChange: (value: string) => void }) {
  const id = `${scope}-${field}`;
  const invalid = Boolean(errors[field]?.length);
  const identifier = field === "username";
  return (
    <div className="field">
      <label htmlFor={id}>{label}</label>
      {hint ? (
        <p id={`${id}-hint`} className="field-hint">
          {hint}
        </p>
      ) : null}
      <input
        id={id}
        name={field}
        type="text"
        required
        value={input.value}
        readOnly={locked}
        autoComplete="off"
        spellCheck={identifier ? false : undefined}
        autoCapitalize={identifier ? "none" : undefined}
        autoCorrect={identifier ? "off" : undefined}
        aria-invalid={invalid || undefined}
        aria-describedby={describedBy(hint && `${id}-hint`, invalid && `${id}-error`)}
        onChange={(event) => input.onChange(event.target.value)}
      />
      <FieldError id={`${id}-error`} field={field} errors={errors} />
    </div>
  );
}

function RoleChoice({ scope, value, errors, locked = false, onChange }: { scope: string; value: PersonRole; errors: FieldErrors; locked?: boolean; onChange: (role: PersonRole) => void }) {
  const id = `${scope}-role`;
  const invalid = Boolean(errors["role"]?.length);
  return (
    <fieldset className="field choice-field" aria-invalid={invalid || undefined} aria-describedby={invalid ? `${id}-error` : undefined}>
      <legend>Role</legend>
      <div className="choice-options">
        {personRoles.map((role) => (
          <div key={role} className="choice-option">
            <input id={`${id}-${role}`} type="radio" name={`${scope}-role`} value={role} checked={value === role} aria-disabled={locked || undefined} onChange={() => (locked ? undefined : onChange(role))} aria-describedby={`${id}-${role}-hint`} />
            <label htmlFor={`${id}-${role}`}>{ROLE_LABELS[role]}</label>
            <p id={`${id}-${role}-hint`} className="field-hint">
              {ROLE_HINTS[role]}
            </p>
          </div>
        ))}
      </div>
      <FieldError id={`${id}-error`} field="role" errors={errors} />
    </fieldset>
  );
}

function PasswordInputs({ scope, errors, onInput, labels }: { scope: string; errors: FieldErrors; onInput: (field: string) => void; labels: [string, string] }) {
  return (
    <>
      {PASSWORD_FIELDS.map((field, index) => {
        const id = `${scope}-${field}`;
        const invalid = Boolean(errors[field]?.length);
        return (
          <div key={field} className="field">
            <label htmlFor={id}>{labels[index]}</label>
            {index === 0 ? (
              <p id={`${id}-hint`} className="field-hint">
                At least 12 characters, with a lowercase letter, an uppercase letter and a number.
              </p>
            ) : null}
            <input
              id={id}
              name={field}
              type="password"
              required
              autoComplete="new-password"
              autoCapitalize="none"
              autoCorrect="off"
              spellCheck={false}
              enterKeyHint={index === 0 ? "next" : "done"}
              aria-invalid={invalid || undefined}
              aria-describedby={describedBy(index === 0 && `${id}-hint`, invalid && `${id}-error`)}
              onInput={() => onInput(field)}
            />
            <FieldError id={`${id}-error`} field={field} errors={errors} />
          </div>
        );
      })}
    </>
  );
}

function readPasswords(form: HTMLFormElement) {
  const data = new FormData(form);
  const read = (name: string) => {
    const value = data.get(name);
    return typeof value === "string" ? value : "";
  };
  return { password: read("password"), password_confirmation: read("password_confirmation") };
}

function missing(values: Record<string, string>, required: readonly string[]): FieldErrors {
  const errors: FieldErrors = {};
  for (const field of required) if ((values[field] ?? "").trim() === "") errors[field] = ["can't be blank"];
  if (values["password"] !== undefined && values["password"] !== "" && values["password"] !== values["password_confirmation"]) errors["password_confirmation"] = ["doesn't match Password"];
  return errors;
}

function focusFirst(form: HTMLFormElement | null, scope: string, order: readonly string[], errors: FieldErrors) {
  const field = order.find((name) => errors[name]?.length);
  if (!form || !field) return;
  const control = form.querySelector<HTMLElement>(field === "role" ? `input[name="${scope}-role"]:checked` : `#${CSS.escape(`${scope}-${field}`)}`);
  control?.focus();
}

function useLeaveGuard() {
  const dirty = useRef(new Set<string>());
  const [count, setCount] = useState(0);
  const mark = useCallback((id: string, isDirty: boolean) => {
    if (isDirty === dirty.current.has(id)) return;
    if (isDirty) dirty.current.add(id);
    else dirty.current.delete(id);
    setCount(dirty.current.size);
  }, []);
  const blocker = useBlocker({
    shouldBlockFn: ({ current, next }) => dirty.current.size > 0 && current.pathname !== next.pathname,
    enableBeforeUnload: () => dirty.current.size > 0,
    withResolver: true,
  });
  const dialog = blocker.status === "blocked" ? <LeaveDialog count={count} onStay={blocker.reset} onLeave={blocker.proceed} /> : null;
  return { mark, dialog, unsaved: count > 0 };
}

function useGate() {
  const session = useSession();
  const admin = useIsAdministrator();
  if (session.isError && !session.data) return <ErrorPanel error={session.error} onRetry={() => void session.refetch()} />;
  if (!session.data) return <Loading label="Loading people…" />;
  if (!admin) return <AdministratorsOnly />;
  return null;
}

function BackToPeople() {
  return (
    <p className="people-back">
      <Link to="/server/$category" params={{ category: "people" }} hash="users">
        <span aria-hidden="true">← </span>People and access
      </Link>
    </p>
  );
}

export function NewPersonPage() {
  const { mode } = useServices();
  if (mode !== "rails") return <NotInThisRuntime />;
  return <NewPersonView />;
}

function NewPersonView() {
  useDocumentTitle("Add a person · Server");
  const gate = useGate();
  const admin = useIsAdministrator();
  return (
    <ServerShell current="people" settings={undefined} headingId="new-person-heading" title="Add a person" summary="Give someone their own sign-in to this server." rail={admin}>
      <BackToPeople />
      {gate ?? <NewPersonForm />}
    </ServerShell>
  );
}

function NewPersonForm() {
  const scope = useId();
  const navigate = useNavigate();
  const add = useAddPerson();
  const writing = usePeopleWriting();
  const form = useRef<HTMLFormElement>(null);
  const [values, setValues] = useState<ProfileValues>({ name: "", username: "", role: "member" });
  const [typed, setTyped] = useState(false);
  const [errors, setErrors] = useState<FieldErrors>({});
  const { said, say, clear } = useSay();
  const guard = useLeaveGuard();
  const dirty = typed || values.name !== "" || values.username !== "" || values.role !== "member";
  useEffect(() => guard.mark("new", dirty));

  const edit = (field: keyof ProfileValues, value: string) => {
    setValues((current) => ({ ...current, [field]: value }));
    clear();
    if (errors[field]) setErrors(({ [field]: _cleared, ...rest }) => rest);
  };

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (writing) return;
    const element = event.currentTarget;
    const passwords = readPasswords(element);
    const entered = { ...values, ...passwords };
    const blank = missing(entered, ["name", "username", "password"]);
    if (Object.keys(blank).length > 0) {
      setErrors(blank);
      say("error", "Nothing was saved. Check the marked fields.");
      focusFirst(element, scope, [...PROFILE_FIELDS, ...PASSWORD_FIELDS], blank);
      return;
    }
    setErrors({});
    clear();
    add.mutate(entered, {
      onSuccess: (answer) => {
        if (answer.kind === "saved") {
          guard.mark("new", false);
          const added = answer.person.user;
          announceArrival(added.id, `${added.name} was added as ${added.role === "administrator" ? "an administrator" : "a member"}. They can sign in with the username ${added.username} and the password you chose.`);
          void navigate({ to: "/server/people/users/$userId", params: { userId: added.id }, ignoreBlocker: true });
          return;
        }
        refuse(answer, element);
      },
      onError: (error) => say("error", peopleFailureText(error)),
    });
  };

  const refuse = (answer: Exclude<PersonAnswer, { kind: "saved" }>, element: HTMLFormElement) => {
    if (answer.kind !== "rejected") {
      say("error", answer.kind === "own_account" ? answer.message : "The server did not accept this. Nothing was changed; reload the page and try again.");
      return;
    }
    setErrors(answer.errors);
    say("error", "Nothing was saved. Check the marked fields.");
    focusFirst(element, scope, [...PROFILE_FIELDS, ...PASSWORD_FIELDS], answer.errors);
  };

  return (
    <SettingsCard id="new-person" headingId={`${scope}-heading`} title="Their sign-in" summary="They can change their name and password later in their own Account.">
      <form ref={form} className="settings-form" method="post" noValidate aria-labelledby={`${scope}-heading`} onSubmit={submit}>
        <TextInput scope={scope} field="name" label="Name" errors={errors} value={values.name} onChange={(value) => edit("name", value)} />
        <TextInput scope={scope} field="username" label="Username" hint="Lowercase letters, numbers and underscores. Capitals are made lowercase." errors={errors} value={values.username} onChange={(value) => edit("username", value)} />
        <PasswordInputs
          scope={scope}
          errors={errors}
          labels={["Password", "Confirm password"]}
          onInput={(field) => {
            setTyped(true);
            clear();
            if (errors[field]) setErrors(({ [field]: _cleared, ...rest }) => rest);
          }}
        />
        <RoleChoice scope={scope} value={values.role} errors={errors} onChange={(role) => edit("role", role)} />
        <CardActions unsaved={dirty}>
          <button type="submit" className="button button--primary" disabled={writing} aria-busy={add.isPending}>
            {add.isPending ? "Adding…" : "Add person"}
          </button>
        </CardActions>
        <Status said={said} />
      </form>
      {guard.dialog}
    </SettingsCard>
  );
}

export function PersonPage() {
  const { mode } = useServices();
  const { userId } = useParams({ from: "/server/people/users/$userId" });
  if (mode !== "rails" || !/^[1-9]\d{0,18}$/.test(userId)) return <NotInThisRuntime />;
  return <PersonView key={userId} id={userId} />;
}

function PersonView({ id }: { id: string }) {
  const gate = useGate();
  const admin = useIsAdministrator();
  const person = usePerson(id);
  const gone = isRemovedPerson(person.error) || (person.isError && failureKind(person.error) === "not_found");
  const record = gone ? undefined : person.data?.user;
  useDocumentTitle(`${record?.name ?? "Person"} · Server`);
  const summary = record ? `${ROLE_LABELS[record.role]} · ${record.username}${record.self ? " · This is you" : ""}` : "";
  const body =
    gate ??
    (isRemovedPerson(person.error) ? (
      <EmptyState title="This person is not on this server">
        <p>They may have been removed. Their requests and history stay on the server.</p>
      </EmptyState>
    ) : person.isError && failureKind(person.error) === "not_found" ? (
      <AdministratorsOnly />
    ) : person.data ? (
      <PersonCards envelope={person.data} />
    ) : person.isError ? (
      <ErrorPanel error={person.error} onRetry={() => void person.refetch()} />
    ) : (
      <Loading label="Loading this person…" />
    ));
  return (
    <ServerShell current="people" settings={undefined} headingId="person-heading" title={record?.name ?? "Person"} summary={summary} rail={admin}>
      <BackToPeople />
      {body}
    </ServerShell>
  );
}

function PersonCards({ envelope }: { envelope: PersonEnvelope }) {
  const person = envelope.user;
  const arrival = useArrival(person.id);
  const { mark, dialog, unsaved } = useLeaveGuard();
  const markProfile = useCallback((dirty: boolean) => mark("profile", dirty), [mark]);
  const markPassword = useCallback((dirty: boolean) => mark("password", dirty), [mark]);
  return (
    <>
      {arrival ? (
        <p className="form-success people-arrival" role="status">
          {arrival}
        </p>
      ) : null}
      <DetailsCard person={person} />
      <ProfileCard envelope={envelope} onDirtyChange={markProfile} />
      {person.self ? <OwnPasswordCard /> : <PasswordCard person={person} onDirtyChange={markPassword} />}
      <RemoveCard person={person} unsaved={unsaved} />
      {dialog}
    </>
  );
}

function DetailsCard({ person }: { person: PersonRecord }) {
  return (
    <SettingsCard id="details" headingId="details-heading" title="Details">
      <dl className="people-details">
        <div>
          <dt>Username</dt>
          <dd>{person.username}</dd>
        </div>
        <div>
          <dt>Role</dt>
          <dd>{ROLE_LABELS[person.role]}</dd>
        </div>
        <div>
          <dt>Added</dt>
          <dd>
            <AddedOn iso={person.created_at} />
          </dd>
        </div>
        <div>
          <dt>Requests</dt>
          <dd>{person.requests.toLocaleString("en")}</dd>
        </div>
      </dl>
    </SettingsCard>
  );
}

type Confirmation = { values: ProfileValues; version: string; shown: string; administrators: number };

function sameValues(left: ProfileValues, right: ProfileValues): boolean {
  return PROFILE_FIELDS.every((field) => left[field] === right[field]);
}

function ProfileCard({ envelope, onDirtyChange }: { envelope: PersonEnvelope; onDirtyChange: (dirty: boolean) => void }) {
  const base = envelope.user;
  const scope = useId();
  const save = useSaveProfile(base.id, base.self);
  const writing = usePeopleWriting();
  const form = useRef<HTMLFormElement>(null);
  const saveButton = useRef<HTMLButtonElement>(null);
  const [edits, setEdits] = useState<Partial<ProfileValues>>({});
  const [startedOn, setStartedOn] = useState<string | null>(null);
  const [errors, setErrors] = useState<FieldErrors>({});
  const [confirmation, setConfirmation] = useState<Confirmation | null>(null);
  const [saving, setSaving] = useState<{ from: string; saved: string | null } | null>(null);
  const sending = saving !== null;
  const { said, say, clear } = useSay();
  const values: ProfileValues = { name: edits.name ?? base.name, username: edits.username ?? base.username, role: edits.role ?? base.role };
  const dirty = PROFILE_FIELDS.some((field) => values[field] !== base[field]);
  const version = dirty && startedOn ? startedOn : base.version;
  const demotingSelf = base.self && base.role === "administrator" && values.role === "member";
  const confirming =
    confirmation !== null && demotingSelf && !writing && confirmation.version === version && confirmation.shown === base.version && confirmation.administrators === envelope.administrators && sameValues(confirmation.values, values);

  useEffect(() => onDirtyChange(dirty), [dirty, onDirtyChange]);
  useEffect(() => () => onDirtyChange(false), [onDirtyChange]);
  useEffect(() => {
    if (Object.keys(edits).length === 0 && startedOn !== null) setStartedOn(null);
  }, [startedOn, edits]);
  useEffect(() => {
    if (saving?.saved == null || (base.version === saving.from && saving.saved !== saving.from)) return;
    setEdits({});
    setSaving(null);
  }, [saving, base.version]);
  useEffect(() => {
    if (confirmation !== null && !confirming) setConfirmation(null);
  }, [confirmation, confirming]);

  const edit = (field: keyof ProfileValues, value: string) => {
    if (sending) return;
    setStartedOn((current) => current ?? base.version);
    setEdits(({ [field]: _replaced, ...rest }) => (value === base[field] ? rest : { ...rest, [field]: value }));
    clear();
    if (errors[field]) setErrors(({ [field]: _cleared, ...rest }) => rest);
  };

  const send = (sent: ProfileValues, sentVersion: string, administrators: number | null) => {
    setConfirmation(null);
    const from = base.version;
    setSaving({ from, saved: null });
    save.mutate(
      { values: sent, version: sentVersion, administrators },
      {
        onError: (error) => {
          setSaving(null);
          say("error", peopleFailureText(error));
        },
        onSuccess: (answer) => {
          setSaving(answer.kind === "saved" ? { from, saved: answer.person.user.version } : null);
          if (answer.kind === "saved") {
            setErrors({});
            say("success", "Changes saved.");
            return;
          }
          if (answer.kind === "changed") {
            setStartedOn(answer.person.user.version);
            say("error", "Someone else changed this person while you were editing. The form now shows what is saved, with your changes on top. Check it and save again.");
            return;
          }
          if (answer.kind === "own_account") {
            say("error", answer.message);
            return;
          }
          setErrors(answer.errors);
          say("error", "Nothing was saved. Check the marked fields.");
          focusFirst(form.current, scope, PROFILE_FIELDS, answer.errors);
        },
      },
    );
  };

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (writing) return;
    clear();
    if (!dirty) {
      say("success", "There are no changes to save.");
      return;
    }
    const blank = missing(values, ["name", "username"]);
    if (Object.keys(blank).length > 0) {
      setErrors(blank);
      say("error", "Nothing was saved. Check the marked fields.");
      focusFirst(event.currentTarget, scope, PROFILE_FIELDS, blank);
      return;
    }
    if (demotingSelf) {
      setConfirmation({ values, version, shown: base.version, administrators: envelope.administrators });
      return;
    }
    send(values, version, null);
  };

  const discard = () => {
    setEdits({});
    setErrors({});
    setConfirmation(null);
    say("success", "Your changes were discarded.");
  };

  return (
    <SettingsCard id="profile" headingId={`${scope}-heading`} title="Name, username and role" summary={base.self ? "Your own name is also yours to change in Account." : undefined}>
      <form ref={form} className="settings-form" method="post" noValidate aria-labelledby={`${scope}-heading`} onSubmit={submit}>
        <TextInput scope={scope} field="name" label="Name" errors={errors} locked={sending} value={values.name} onChange={(value) => edit("name", value)} />
        <TextInput scope={scope} field="username" label="Username" hint="Lowercase letters, numbers and underscores. They sign in with it." errors={errors} locked={sending} value={values.username} onChange={(value) => edit("username", value)} />
        <RoleChoice scope={scope} value={values.role} errors={errors} locked={sending} onChange={(role) => edit("role", role)} />
        <CardActions unsaved={dirty}>
          <button ref={saveButton} type="submit" className="button button--primary" disabled={writing} aria-busy={save.isPending}>
            {save.isPending ? "Saving…" : "Save changes"}
          </button>
          {dirty ? (
            <button type="button" className="button button--subtle" onClick={discard} disabled={writing}>
              Discard changes
            </button>
          ) : null}
        </CardActions>
        {confirming ? (
          <DemoteSelf
            alone={envelope.administrators <= 1}
            onConfirm={() => send(confirmation.values, confirmation.version, confirmation.administrators)}
            onCancel={() => {
              setConfirmation(null);
              saveButton.current?.focus();
            }}
          />
        ) : null}
        <Status said={said} />
      </form>
    </SettingsCard>
  );
}

function DemoteSelf({ alone, onConfirm, onCancel }: { alone: boolean; onConfirm: () => void; onCancel: () => void }) {
  const confirm = useRef<HTMLButtonElement>(null);
  const questionId = useId();
  useEffect(() => confirm.current?.focus(), []);
  return (
    <div className="people-confirm" role="group" aria-labelledby={questionId}>
      <p id={questionId} className="people-confirm-question">
        <strong>Make yourself a member?</strong> You will lose access to Server as soon as this is saved.{" "}
        {alone ? "No one else is an administrator, so nobody will be able to change server settings or people in Shelfarr." : "Another administrator can make you an administrator again."}
      </p>
      <div className="form-actions">
        <button ref={confirm} type="button" className="button button--danger" onClick={onConfirm}>
          Make me a member
        </button>
        <button type="button" className="button button--subtle" onClick={onCancel}>
          Keep me an administrator
        </button>
      </div>
    </div>
  );
}

function OwnPasswordCard() {
  return (
    <SettingsCard id="password" headingId="own-password-heading" title="Password" summary="Your own password is changed in Account, where your current password is asked for.">
      <p>
        <Link to="/account/$section" params={{ section: "security" }} className="button">
          Open Sign-in and security
        </Link>
      </p>
    </SettingsCard>
  );
}

function PasswordCard({ person, onDirtyChange }: { person: PersonRecord; onDirtyChange: (dirty: boolean) => void }) {
  const scope = useId();
  const setPassword = useSetPassword(person.id);
  const writing = usePeopleWriting();
  const [errors, setErrors] = useState<FieldErrors>({});
  const [typed, setTyped] = useState(false);
  const { said, say, clear } = useSay();

  useEffect(() => onDirtyChange(typed), [typed, onDirtyChange]);
  useEffect(() => () => onDirtyChange(false), [onDirtyChange]);

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (writing) return;
    const element = event.currentTarget;
    const passwords = readPasswords(element);
    clear();
    const blank = missing(passwords, ["password"]);
    if (Object.keys(blank).length > 0) {
      setErrors(blank);
      say("error", "Nothing was saved. Check the marked fields.");
      focusFirst(element, scope, PASSWORD_FIELDS, blank);
      return;
    }
    setErrors({});
    setPassword.mutate(passwords, {
      onSuccess: (answer) => {
        if (answer.kind === "saved") {
          element.reset();
          setTyped(false);
          say("success", `New password set for ${answer.person.user.name}. Browsers where they are already signed in stay signed in.`);
          return;
        }
        if (answer.kind === "rejected") {
          setErrors(answer.errors);
          say("error", "The password was not changed. Check the marked fields.");
          focusFirst(element, scope, PASSWORD_FIELDS, answer.errors);
          return;
        }
        say("error", answer.kind === "own_account" ? answer.message : "The server did not accept this. Nothing was changed; reload the page and try again.");
      },
      onError: (error) => say("error", peopleFailureText(error)),
    });
  };

  return (
    <SettingsCard id="password" headingId={`${scope}-heading`} title="Set a new password" summary={`For when ${person.name} cannot sign in. Tell them the new password yourself; Shelfarr does not send it.`}>
      <form className="settings-form" method="post" noValidate aria-labelledby={`${scope}-heading`} onSubmit={submit}>
        <input type="text" name="username" autoComplete="username" value={person.username} readOnly hidden />
        <PasswordInputs
          scope={scope}
          errors={errors}
          labels={["New password", "Confirm new password"]}
          onInput={(field) => {
            setTyped(true);
            clear();
            if (errors[field]) setErrors(({ [field]: _cleared, ...rest }) => rest);
          }}
        />
        <CardActions unsaved={typed}>
          <button type="submit" className="button button--primary" disabled={writing} aria-busy={setPassword.isPending}>
            {setPassword.isPending ? "Setting…" : "Set password"}
          </button>
        </CardActions>
        <Status said={said} />
      </form>
    </SettingsCard>
  );
}

function RemoveCard({ person, unsaved }: { person: PersonRecord; unsaved: boolean }) {
  const navigate = useNavigate();
  const remove = useRemovePerson(person.id);
  const writing = usePeopleWriting();
  const { said, say } = useSay();
  if (person.self) {
    return (
      <SettingsCard id="remove" headingId="remove-heading" title="Remove">
        <p className="field-hint">You cannot remove your own account. Another administrator can remove it.</p>
      </SettingsCard>
    );
  }
  const confirm = () => {
    if (writing) return;
    remove.mutate(person.version, {
      onSuccess: (answer) => {
        if (answer.kind === "removed") {
          announceArrival(PEOPLE_ARRIVAL, `${person.name} was removed.`);
          void navigate({ to: "/server/$category", params: { category: "people" }, hash: "users", ignoreBlocker: true });
          return;
        }
        if (answer.kind === "changed") {
          say("error", "Someone else changed this person since you opened the page. Nothing was removed. Check the details above and remove again if you still want to.");
          return;
        }
        say("error", answer.kind === "own_account" ? answer.message : "The server did not accept this. Nothing was changed; reload the page and try again.");
      },
      onError: (error) => say("error", peopleFailureText(error)),
    });
  };
  return (
    <SettingsCard
      id="remove"
      headingId="remove-heading"
      title="Remove"
      summary="Removing signs them out of every browser and stops their apps, API tokens and Kobo readers from connecting. Their Hardcover follows are paused and their Hardcover account is disconnected. Their requests and reading history stay on the server, and their username can be given to a new account. This cannot be undone in Shelfarr."
    >
      <div className="settings-card-actions">
        <RemoveZone key={person.version} label={`Remove ${person.name}`} confirmLabel="Remove" question={`Remove ${person.name} (${person.username}) from this server?${unsaved ? " Your unsaved changes on this page will be lost." : ""}`} busy={remove.isPending || writing} onRemove={confirm} />
      </div>
      <Status said={said} />
    </SettingsCard>
  );
}
