import { Link, useLocation } from "@tanstack/react-router";
import { useEffect, useId, useRef, useState, type FormEvent } from "react";
import { describeWriteFailure } from "../../components/accountFields";
import { Time } from "../../components/requestText";
import { ErrorPanel, Loading } from "../../components/States";
import { useServices } from "../../services";
import * as koboApi from "./api";
import type { KoboReaderRow, KoboReaders, KoboSettings, KoboSetup } from "./contract";
import { ManageReaderLink, SetupInstructions, SyncOptions } from "./KoboParts";
import { useKoboPublish, useKoboReaders } from "./queries";

export function KoboReadersCard() {
  const headingId = useId();
  const readers = useKoboReaders();
  const [setup, setSetup] = useState<KoboSetup | null>(null);
  const section = useRef<HTMLElement>(null);
  const hash = useLocation({ select: (location) => location.hash });
  const ready = readers.data !== undefined;
  useEffect(() => {
    if (hash !== "kobo-readers" || !ready) return;
    section.current?.scrollIntoView({ block: "start" });
    section.current?.focus({ preventScroll: true });
  }, [hash, ready]);
  return (
    <section ref={section} id="kobo-readers" className="account-card" aria-labelledby={headingId} tabIndex={-1}>
      <h2 id={headingId}>Kobo readers</h2>
      <p className="muted">Send library ebooks to each reader, then sync it over Wi-Fi. Works with stock Kobo software; no alternative reader app needed.</p>
      <div className="kobo-preview-note" role="note">
        <p className="kobo-option-title">Preview · physical-device testing in progress</p>
        <p>Each reader can keep its own Kobo Store library beside Shelfarr books, or sync Shelfarr books only. Shelfarr never changes Store purchases or signs the reader out. EPUB and KEPUB only; no PDF or DRM in this preview.</p>
      </div>
      {readers.data ? (
        <>
          <ReaderList readers={readers.data.readers} />
          {setup ? (
            <SetupInstructions setup={setup.setup} name={setup.reader.name} storeCoexistence={setup.reader.store_coexistence} done={<ManageReaderLink id={setup.reader.id} />} onDone={() => setSetup(null)} />
          ) : (
            <ConnectReader defaults={readers.data.new_reader} onCreated={setSetup} />
          )}
        </>
      ) : readers.isError ? (
        <ErrorPanel error={readers.error} onRetry={() => void readers.refetch()} />
      ) : (
        <Loading label="Loading your Kobo readers…" />
      )}
    </section>
  );
}

function ReaderList({ readers }: { readers: KoboReaderRow[] }) {
  if (readers.length === 0) return <p>No Kobo reader is connected to your account.</p>;
  return (
    <ul className="kobo-reader-list">
      {readers.map((reader) => (
        <li key={reader.id}>
          <div>
            <p className="token-name">
              <Link to="/account/devices/kobo/$readerId" params={{ readerId: reader.id }}>
                {reader.name}
              </Link>
            </p>
            <p className="request-meta">
              <span>{reader.mode_label}</span>
              <SyncLine at={reader.last_sync_at} />
            </p>
          </div>
        </li>
      ))}
    </ul>
  );
}

export function SyncLine({ at, first = "Waiting for first sync" }: { at: string | null; first?: string }) {
  return at ? (
    <span>
      Last sync request <Time iso={at} relative />
    </span>
  ) : (
    <span>{first}</span>
  );
}

type Draft = KoboSettings & { name: string; base_url: string };
const FIELDS = ["name", "base_url"] as const;
const LABELS: Record<string, string> = { name: "Reader name", base_url: "Shelfarr address" };

function ConnectReader({ defaults, onCreated }: { defaults: KoboReaders["new_reader"]; onCreated: (setup: KoboSetup) => void }) {
  const { api } = useServices();
  const publish = useKoboPublish();
  const ids = { heading: useId(), name: useId(), address: useId(), help: useId(), nameError: useId(), addressError: useId() };
  const form = useRef<HTMLFormElement>(null);
  const mounted = useRef(true);
  const sending = useRef(false);
  const [draft, setDraft] = useState<Draft>(() => ({ name: "", ...defaults }));
  const [pending, setPending] = useState(false);
  const [errors, setErrors] = useState<Record<string, string[]>>({});
  const [problem, setProblem] = useState<string | null>(null);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  const focusFirst = (found: Record<string, string[]>) => {
    const field = FIELDS.find((name) => found[name]?.length);
    const control = field ? form.current?.elements.namedItem(field) : null;
    if (control instanceof HTMLInputElement) control.focus();
  };

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (sending.current) return;
    const missing: Record<string, string[]> = {};
    if (draft.name.trim() === "") missing["name"] = ["Enter a name for this reader."];
    if (draft.base_url.trim() === "") missing["base_url"] = ["Enter the address this reader uses to reach Shelfarr."];
    setProblem(null);
    setErrors(missing);
    if (Object.keys(missing).length) {
      focusFirst(missing);
      return;
    }
    sending.current = true;
    setPending(true);
    try {
      const answer = await koboApi.createReader(api, draft);
      if (!mounted.current || !publish.active()) return;
      if (answer.kind === "created") {
        publish.refresh();
        setDraft({ name: "", ...defaults });
        onCreated(answer.setup);
        return;
      }
      const own = Object.fromEntries(FIELDS.flatMap((field) => (answer.errors[field]?.length ? [[field, answer.errors[field].map((message) => `${LABELS[field]} ${message}.`)]] : [])));
      setErrors(own);
      setProblem(`The reader was not connected. ${Object.keys(own).length ? "Check the marked fields." : `${answer.messages.join(". ")}.`}`);
      focusFirst(own);
    } catch (error) {
      if (!mounted.current) return;
      publish.lost(error);
      publish.refresh();
      setProblem(describeWriteFailure(error, "Shelfarr could not confirm whether the reader was connected. Check the list above; if it appears there, open it and make a new connection address."));
    } finally {
      sending.current = false;
      if (mounted.current) setPending(false);
    }
  }

  const invalid = (field: string) => Boolean(errors[field]?.length);
  const change = (next: Partial<Draft>) => {
    setDraft((current) => ({ ...current, ...next }));
    setProblem(null);
  };
  return (
    <section className="kobo-connect" aria-labelledby={ids.heading}>
      <h3 id={ids.heading}>Connect a reader</h3>
      <form ref={form} className="account-form" method="post" noValidate aria-labelledby={ids.heading} onSubmit={(event) => void submit(event)}>
        <div className="field">
          <label htmlFor={ids.name}>Reader name</label>
          <input
            id={ids.name}
            name="name"
            type="text"
            required
            maxLength={80}
            placeholder="My Kobo"
            autoComplete="off"
            value={draft.name}
            aria-invalid={invalid("name")}
            aria-describedby={invalid("name") ? ids.nameError : undefined}
            onChange={(event) => {
              change({ name: event.target.value });
              if (invalid("name")) setErrors(({ name: _cleared, ...rest }) => rest);
            }}
          />
          {invalid("name") ? (
            <p id={ids.nameError} className="field-error">
              <span aria-hidden="true">⚠ </span>
              {errors["name"]?.join(" ")}
            </p>
          ) : null}
        </div>
        <div className="field">
          <label htmlFor={ids.address}>Shelfarr address reachable from this reader</label>
          <input
            id={ids.address}
            name="base_url"
            type="url"
            required
            inputMode="url"
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            value={draft.base_url}
            aria-invalid={invalid("base_url")}
            aria-describedby={invalid("base_url") ? `${ids.help} ${ids.addressError}` : ids.help}
            onChange={(event) => {
              change({ base_url: event.target.value });
              if (invalid("base_url")) setErrors(({ base_url: _cleared, ...rest }) => rest);
            }}
          />
          <p id={ids.help} className="field-hint">
            Use HTTPS where possible. Include any server subpath. A browser login or Cloudflare Access page will block the Kobo.
          </p>
          {invalid("base_url") ? (
            <p id={ids.addressError} className="field-error">
              <span aria-hidden="true">⚠ </span>
              {errors["base_url"]?.join(" ")}
            </p>
          ) : null}
        </div>
        <SyncOptions values={draft} disabled={pending} onChange={(values) => change(values)} />
        <div className="form-actions">
          <button type="submit" className="button button--primary" disabled={pending} aria-busy={pending}>
            {pending ? "Creating connection…" : "Create connection"}
          </button>
        </div>
        <div className="form-outcome" role="status">
          {problem ? <p className="form-error">{problem}</p> : null}
        </div>
      </form>
    </section>
  );
}
