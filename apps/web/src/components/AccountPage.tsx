import { useEffect, useId, useRef, useState, type FormEvent, type RefObject } from "react";
import { ApiError, failureKind } from "../api/errors";
import type { Profile } from "../contract";
import { useDisplayName, useProfile } from "../queries";
import { useServices } from "../services";
import { usePageTitle } from "../title";
import { describeWriteFailure, fieldMessage, firstInvalid, isBlank, recordRefusal, splitErrors, type FieldErrors, type FormOutcome } from "./accountFields";
import { PageHeading } from "./PageHeading";
import { EmptyState, ErrorPanel, Loading } from "./States";

const NAME_FIELDS = ["name"] as const;
const PASSWORD_FIELDS = ["current_password", "password", "password_confirmation"] as const;

export function AccountPage() {
  const { mode } = useServices();
  if (mode !== "go") {
    return (
      <EmptyState title="That page is not part of this preview">
        <p>Use the navigation to return to your library.</p>
      </EmptyState>
    );
  }
  return <AccountSettings />;
}

function AccountSettings() {
  usePageTitle("Account");
  const profile = useProfile();
  return (
    <section className="account" aria-labelledby="account-heading">
      <PageHeading id="account-heading">Account</PageHeading>
      <p className="lede">Your name and password for signing in to this server. Changes here apply to the classic Shelfarr app too.</p>
      {profile.data ? (
        <>
          <Identity profile={profile.data} />
          <DisplayNameForm profile={profile.data} />
          <PasswordForm profile={profile.data} />
        </>
      ) : profile.isError && failureKind(profile.error) === "not_found" ? (
        <EmptyState title="Account settings are not available here">
          <p>This server does not offer account settings yet. Nothing was changed.</p>
        </EmptyState>
      ) : profile.isError ? (
        <ErrorPanel error={profile.error} onRetry={() => void profile.refetch()} />
      ) : (
        <Loading label="Loading your account…" />
      )}
    </section>
  );
}

function Identity({ profile }: { profile: Profile }) {
  return (
    <section className="account-card" aria-labelledby="identity-heading">
      <h2 id="identity-heading">Signed in as</h2>
      <dl className="identity">
        <div>
          <dt>Display name</dt>
          <dd>{profile.name}</dd>
        </div>
        <div>
          <dt>Username</dt>
          <dd>@{profile.username}</dd>
        </div>
      </dl>
    </section>
  );
}

function FieldError({ id, field, errors }: { id: string; field: string; errors: FieldErrors }) {
  const messages = errors[field];
  if (!messages?.length) return null;
  return (
    <p id={id} className="field-error">
      <span aria-hidden="true">⚠ </span>
      {fieldMessage(field, messages)}
    </p>
  );
}

function describedBy(...ids: (string | false)[]): string | undefined {
  const present = ids.filter((id): id is string => Boolean(id));
  return present.length ? present.join(" ") : undefined;
}

function Outcome({ outcome }: { outcome: FormOutcome }) {
  return (
    <div className="form-outcome" role="status">
      {outcome ? <p className={outcome.tone === "error" ? "form-error" : "form-success"}>{outcome.text}</p> : null}
    </div>
  );
}

function useFocusOnRefusal(form: RefObject<HTMLFormElement | null>, fields: readonly string[], errors: FieldErrors): () => void {
  const [requested, setRequested] = useState(0);
  const handled = useRef(0);
  useEffect(() => {
    if (requested === handled.current) return;
    handled.current = requested;
    firstInvalid(form.current, fields, errors);
  }, [requested, form, fields, errors]);
  return () => setRequested((count) => count + 1);
}

function DisplayNameForm({ profile }: { profile: Profile }) {
  const ids = { heading: useId(), input: useId(), error: useId() };
  const form = useRef<HTMLFormElement>(null);
  const saving = useRef(false);
  const edits = useRef(0);
  const mutation = useDisplayName();
  const { queryClient, keys } = useServices();
  const [draft, setDraft] = useState<string | null>(null);
  const [errors, setErrors] = useState<FieldErrors>({});
  const [outcome, setOutcome] = useState<FormOutcome>(null);
  const focusRefusal = useFocusOnRefusal(form, NAME_FIELDS, errors);
  const value = draft ?? profile.name;

  function refuse(found: FieldErrors) {
    setErrors(found);
    setOutcome({ tone: "error", text: "The name was not saved. Check the marked field." });
    focusRefusal();
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (saving.current) return;
    setOutcome(null);
    if (isBlank(value)) {
      refuse({ name: ["can't be blank"] });
      return;
    }
    setErrors({});
    saving.current = true;
    const revision = edits.current;
    mutation.mutate(value, {
      onSettled: () => {
        saving.current = false;
      },
      onSuccess: (answer) => {
        const current = edits.current === revision;
        if (answer.kind === "saved") {
          if (current) setDraft(null);
          setOutcome({ tone: "success", text: current ? "Display name saved." : "The earlier name was saved. Your newer change is not saved yet." });
          return;
        }
        const { own, record } = splitErrors(answer.errors, NAME_FIELDS);
        if (record.length) {
          setOutcome({ tone: "error", text: recordRefusal(record) });
          return;
        }
        if (current) refuse(own);
        else setOutcome({ tone: "error", text: `The earlier name was not saved: ${fieldMessage("name", own["name"] ?? [])}` });
      },
      onError: (error) => {
        void queryClient.invalidateQueries({ queryKey: keys.profile });
        setOutcome({ tone: "error", text: describeWriteFailure(error, "Shelfarr could not confirm whether the name was saved. The name shown above is what the server has now; save again if it is not the one you want.") });
      },
    });
  }

  const invalid = Boolean(errors["name"]?.length);
  return (
    <section className="account-card" aria-labelledby={ids.heading}>
      <h2 id={ids.heading}>Display name</h2>
      <form ref={form} className="account-form" method="post" noValidate aria-labelledby={ids.heading} onSubmit={submit}>
        <div className="field">
          <label htmlFor={ids.input}>Display name</label>
          <input
            id={ids.input}
            name="name"
            type="text"
            autoComplete="nickname"
            enterKeyHint="done"
            required
            value={value}
            aria-invalid={invalid}
            aria-describedby={describedBy(invalid && ids.error)}
            onChange={(event) => {
              edits.current += 1;
              setDraft(event.target.value);
              setOutcome(null);
              if (invalid) setErrors({});
            }}
          />
          <FieldError id={ids.error} field="name" errors={errors} />
        </div>
        <div className="form-actions">
          <button type="submit" className="button button--primary" disabled={mutation.isPending} aria-busy={mutation.isPending}>
            {mutation.isPending ? "Saving…" : "Save name"}
          </button>
        </div>
        <Outcome outcome={outcome} />
      </form>
    </section>
  );
}

function PasswordForm({ profile }: { profile: Profile }) {
  const ids = { heading: useId(), hint: useId(), note: useId(), current: useId(), password: useId(), confirmation: useId(), errors: { current_password: useId(), password: useId(), password_confirmation: useId() } };
  const form = useRef<HTMLFormElement>(null);
  const submitting = useRef(false);
  const mounted = useRef(true);
  const { api } = useServices();
  const [pending, setPending] = useState(false);
  const [errors, setErrors] = useState<FieldErrors>({});
  const [outcome, setOutcome] = useState<FormOutcome>(null);
  const focusRefusal = useFocusOnRefusal(form, PASSWORD_FIELDS, errors);

  function refuse(found: FieldErrors) {
    setErrors(found);
    setOutcome({ tone: "error", text: "The password was not changed. Check the marked fields." });
    focusRefusal();
  }

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  function clearField(field: string) {
    setOutcome(null);
    if (errors[field]?.length) setErrors(({ [field]: _cleared, ...rest }) => rest);
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (submitting.current) return;
    const element = event.currentTarget;
    const data = new FormData(element);
    const read = (name: string) => {
      const entry = data.get(name);
      return typeof entry === "string" ? entry : "";
    };
    const change = { current_password: read("current_password"), password: read("password"), password_confirmation: read("password_confirmation") };
    const missing: FieldErrors = {};
    if (change.current_password === "") missing["current_password"] = ["can't be blank"];
    if (change.password === "") missing["password"] = ["can't be blank"];
    if (change.password !== change.password_confirmation) missing["password_confirmation"] = ["doesn't match Password"];
    setOutcome(null);
    setErrors({});
    if (Object.keys(missing).length) {
      refuse(missing);
      return;
    }
    submitting.current = true;
    setPending(true);
    try {
      const answer = await api.changePassword(change);
      if (!mounted.current) return;
      if (answer.kind === "saved") {
        element.reset();
        setOutcome({ tone: "success", text: "Password changed. You are still signed in here; every other browser signed in to this account has been signed out. Apps connected to your account stay connected." });
        return;
      }
      const { own, record } = splitErrors(answer.errors, PASSWORD_FIELDS);
      if (record.length) setOutcome({ tone: "error", text: recordRefusal(record) });
      else refuse(own);
    } catch (error) {
      if (!mounted.current) return;
      const text = describeWriteFailure(
        error,
        "Shelfarr could not confirm whether your password changed. It may have been saved. Your entries are still here: you can submit again, and if your current password is then refused, your password has changed since this page was opened.",
      );
      if (error instanceof ApiError && error.kind === "conflict") {
        const field = element.elements.namedItem("current_password");
        if (field instanceof HTMLInputElement) {
          field.value = "";
          field.focus();
        }
      }
      setOutcome({ tone: "error", text });
    } finally {
      submitting.current = false;
      if (mounted.current) setPending(false);
    }
  }

  const fieldProps = (field: (typeof PASSWORD_FIELDS)[number], hint?: string) => {
    const invalid = Boolean(errors[field]?.length);
    return {
      name: field,
      type: "password",
      autoCapitalize: "none",
      autoCorrect: "off",
      spellCheck: false,
      required: true,
      "aria-invalid": invalid,
      "aria-describedby": describedBy(hint ?? false, invalid && ids.errors[field]),
      onChange: () => clearField(field),
    };
  };

  return (
    <section className="account-card" aria-labelledby={ids.heading}>
      <h2 id={ids.heading}>Change password</h2>
      <p id={ids.note} className="muted">
        Changing your password signs out every other browser signed in to this account. This browser stays signed in, and apps connected to your account stay connected.
      </p>
      <form ref={form} className="account-form" method="post" noValidate aria-labelledby={ids.heading} aria-describedby={ids.note} onSubmit={(event) => void submit(event)}>
        <input type="text" name="username" autoComplete="username" value={profile.username} readOnly hidden />
        <div className="field">
          <label htmlFor={ids.current}>Current password</label>
          <input id={ids.current} autoComplete="current-password" enterKeyHint="next" {...fieldProps("current_password")} />
          <FieldError id={ids.errors.current_password} field="current_password" errors={errors} />
        </div>
        <div className="field">
          <label htmlFor={ids.password}>New password</label>
          <p id={ids.hint} className="field-hint">
            At least 12 characters, with a lowercase letter, an uppercase letter and a number.
          </p>
          <input id={ids.password} autoComplete="new-password" enterKeyHint="next" {...fieldProps("password", ids.hint)} />
          <FieldError id={ids.errors.password} field="password" errors={errors} />
        </div>
        <div className="field">
          <label htmlFor={ids.confirmation}>Confirm new password</label>
          <input id={ids.confirmation} autoComplete="new-password" enterKeyHint="done" {...fieldProps("password_confirmation")} />
          <FieldError id={ids.errors.password_confirmation} field="password_confirmation" errors={errors} />
        </div>
        <div className="form-actions">
          <button type="submit" className="button button--primary" disabled={pending} aria-busy={pending}>
            {pending ? "Changing password…" : "Change password"}
          </button>
        </div>
        <Outcome outcome={outcome} />
      </form>
    </section>
  );
}
