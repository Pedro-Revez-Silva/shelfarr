import { Link } from "@tanstack/react-router";
import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { CopyButton } from "../../components/PersonalSettings";
import type { KoboNotice, KoboSettings, KoboSetup } from "./contract";
import "./kobo.css";

export function ToneLine({ notice, testId }: { notice: KoboNotice; testId?: string }) {
  return (
    <p className={`kobo-tone kobo-tone--${notice.tone}`} data-testid={testId}>
      {notice.text}
    </p>
  );
}

export function SyncOptions({ values, disabled = false, onChange }: { values: KoboSettings; disabled?: boolean; onChange: (values: KoboSettings) => void }) {
  const ids = { store: useId(), local: useId(), share: useId(), receive: useId(), mode: useId(), titles: { store: useId(), local: useId(), share: useId(), receive: useId() } };
  const set = (change: Partial<KoboSettings>) => onChange({ ...values, ...change });
  return (
    <>
      <fieldset className="kobo-options" disabled={disabled}>
        <legend>Kobo Store on this reader</legend>
        <label className="kobo-option">
          <input type="radio" name={ids.mode} checked={values.store_coexistence} aria-labelledby={ids.titles.store} aria-describedby={ids.store} onChange={() => set({ store_coexistence: true })} />
          <span>
            <span id={ids.titles.store} className="kobo-option-title">
              Keep my Kobo Store library <span className="kobo-badge">Recommended</span>
            </span>
            <span id={ids.store} className="field-hint">
              Shelfarr books appear beside your purchases. The reader stays signed in to its own Kobo account: Shelfarr passes Store requests to Kobo and never saves that sign-in. Needs an HTTPS address.
            </span>
          </span>
        </label>
        <label className="kobo-option">
          <input type="radio" name={ids.mode} checked={!values.store_coexistence} aria-labelledby={ids.titles.local} aria-describedby={ids.local} onChange={() => set({ store_coexistence: false })} />
          <span>
            <span id={ids.titles.local} className="kobo-option-title">
              Shelfarr books only
            </span>
            <span id={ids.local} className="field-hint">
              Replaces Store syncing. Store books already on the reader stay, but new purchases and Store reading places wait until you restore the original endpoint.
            </span>
          </span>
        </label>
      </fieldset>
      <fieldset className="kobo-options" disabled={disabled}>
        <legend>Reading places</legend>
        <label className="kobo-option">
          <input type="checkbox" checked={values.share_progress} aria-labelledby={ids.titles.share} aria-describedby={ids.share} onChange={(event) => set({ share_progress: event.target.checked })} />
          <span>
            <span id={ids.titles.share} className="kobo-option-title">
              Share reading places with Shelfarr
            </span>
            <span id={ids.share} className="field-hint">
              From this Kobo to Shelfarr. When you read a Shelfarr book on this Kobo, the web and mobile readers resume there, if it is the same edition and the most recent place. Kobo places are shared by chapter and percentage, so the exact page can differ. Places that can't be compared automatically wait on the reader's page for you to choose.
            </span>
          </span>
        </label>
        <label className="kobo-option">
          <input type="checkbox" checked={values.receive_progress} aria-labelledby={ids.titles.receive} aria-describedby={ids.receive} onChange={(event) => set({ receive_progress: event.target.checked })} />
          <span>
            <span id={ids.titles.receive} className="kobo-option-title">
              Receive Shelfarr reading places <span className="kobo-badge kobo-badge--preview">Preview</span>
            </span>
            <span id={ids.receive} className="field-hint">
              From Shelfarr to this Kobo. After you read in the web reader or the Android or iOS app, this Kobo opens the book there at its next Wi-Fi sync. Books sent from your library can receive places: EPUB files are sent as a Kobo edition (KEPUB) that Shelfarr prepares from the original, which stays unchanged, and KEPUB files are sent as they are. Kobo opens the same chapter at the nearest sentence marker, so the page can differ slightly. Plain EPUB files sent before Kobo editions (until you send them again), books shared from Kobo accounts and Kobo Store books keep their Kobo place, and a newer place on this Kobo is never replaced. Not yet tested on a physical Kobo.
            </span>
          </span>
        </label>
      </fieldset>
    </>
  );
}

export function SetupInstructions({ setup, name, storeCoexistence, onDone, done }: { setup: KoboSetup["setup"]; name: string; storeCoexistence: boolean; onDone?: () => void; done: ReactNode }) {
  const headingId = useId();
  const heading = useRef<HTMLHeadingElement>(null);
  useEffect(() => heading.current?.focus(), []);
  const line = `api_endpoint=${setup.endpoint}`;
  return (
    <section className="kobo-setup" aria-labelledby={headingId} data-testid="kobo-setup">
      <h3 id={headingId} ref={heading} tabIndex={-1}>
        Connect {name}
      </h3>
      <p className="kobo-secret-warning">
        This private connection address is shown once. Anyone with it can download books selected for this reader{storeCoexistence ? " and relay this reader's Store requests" : ""}. Keep it secret.
      </p>
      <div className="kobo-mode" data-testid="kobo-mode">
        {storeCoexistence ? (
          <>
            <p className="kobo-option-title">Mode: Kobo Store + Shelfarr</p>
            <p>Keep the reader signed in to its Kobo account. Your Store library, purchases and Store reading places keep syncing, and Shelfarr books arrive beside them. Shelfarr passes Store requests to Kobo using the reader's own sign-in and does not save it.</p>
          </>
        ) : (
          <>
            <p className="kobo-option-title">Mode: Shelfarr books only</p>
            <p>Store syncing pauses while this address is in use. Store books already on the reader stay. Restore the original endpoint to sync new purchases again.</p>
          </>
        )}
      </div>
      <ol className="steps-list">
        <li>
          Connect this Kobo to your computer by USB. Back up <code>.kobo/Kobo/Kobo eReader.conf</code> from the reader, including its original <code>api_endpoint</code>.
        </li>
        <li>
          Open the configuration file with a plain text editor. In the existing <code>[OneStoreServices]</code> section, replace only the <code>api_endpoint</code> line with:
          <pre className="kobo-endpoint" data-testid="kobo-endpoint">
            {line}
          </pre>
          <span className="form-actions">
            <CopyButton text={line} label="Copy this line" />
          </span>
        </li>
        <li>
          Save the file, safely eject the Kobo, then restart it. Open a library ebook in Shelfarr and choose <strong>Send to Kobo</strong>.
        </li>
        <li>
          On the Kobo, connect to Wi-Fi and tap <strong>Sync</strong>. Books arrive when the reader syncs; Shelfarr cannot wake it remotely.
        </li>
      </ol>
      <RestoreStore storeEndpoint={setup.store_endpoint} />
      <p className="muted">Use a different connection for each physical reader. If the connection address is lost, make a new one from the reader's page. You can change the mode there later without editing the reader again.</p>
      <div className="form-actions">
        {done}
        {onDone ? (
          <button type="button" className="button button--subtle" onClick={onDone}>
            Hide the address
          </button>
        ) : null}
      </div>
    </section>
  );
}

export function RestoreStore({ storeEndpoint }: { storeEndpoint: string }) {
  return (
    <div className="kobo-restore">
      <p className="kobo-option-title">To go back to Kobo only</p>
      <p>Put your saved line back. If the backup is lost, the stock line is:</p>
      <pre className="kobo-endpoint kobo-endpoint--store" data-testid="kobo-store-endpoint">
        api_endpoint={storeEndpoint}
      </pre>
      <p className="muted">Do not sign out of, reset or delete the database on the reader to troubleshoot this connection; that can remove downloaded books.</p>
    </div>
  );
}

export function ManageReaderLink({ id }: { id: string }) {
  return (
    <Link to="/account/devices/kobo/$readerId" params={{ readerId: id }} className="button button--primary">
      Done · manage reader
    </Link>
  );
}

export function ConfirmAction({ label, question, confirmLabel, busy, danger = false, onConfirm }: { label: ReactNode; question: string | null; confirmLabel: string; busy: boolean; danger?: boolean; onConfirm: () => void }) {
  const [asking, setAsking] = useState(false);
  const confirm = useRef<HTMLButtonElement>(null);
  const start = useRef<HTMLButtonElement>(null);
  const wasAsking = useRef(false);
  useEffect(() => {
    if (asking) confirm.current?.focus();
    else if (wasAsking.current) start.current?.focus();
    wasAsking.current = asking;
  }, [asking]);
  const startClass = danger ? "button button--subtle button--danger" : "button";
  if (question === null) {
    return (
      <button type="button" className={startClass} aria-disabled={busy ? true : undefined} aria-busy={busy} onClick={() => (busy ? undefined : onConfirm())}>
        {label}
      </button>
    );
  }
  if (!asking) {
    return (
      <button ref={start} type="button" className={startClass} onClick={() => setAsking(true)}>
        {label}
      </button>
    );
  }
  return (
    <span className="remove-zone" role="group" aria-label={question}>
      <span className="remove-zone-question">{question}</span>
      <button
        ref={confirm}
        type="button"
        className={danger ? "button button--danger" : "button button--primary"}
        aria-disabled={busy ? true : undefined}
        aria-busy={busy}
        onClick={() => {
          if (busy) return;
          setAsking(false);
          onConfirm();
        }}
      >
        {confirmLabel}
      </button>
      <button type="button" className="button button--subtle" onClick={() => setAsking(false)}>
        Keep it
      </button>
    </span>
  );
}
