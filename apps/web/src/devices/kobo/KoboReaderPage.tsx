import { useQueryClient } from "@tanstack/react-query";
import { getRouteApi, Link, useBlocker } from "@tanstack/react-router";
import { useEffect, useId, useRef, useState, type FormEvent } from "react";
import { describeWriteFailure } from "../../components/accountFields";
import { PageHeading } from "../../components/PageHeading";
import { AccountRail } from "../../components/PersonalSettings";
import { EmptyState, ErrorPanel, Loading } from "../../components/States";
import { Said, useSay } from "../../server/extras";
import { RemoveZone } from "../../server/primitives";
import { LeaveDialog } from "../../server/ServerCategoryPage";
import { useServices } from "../../services";
import { useDocumentTitle } from "../../title";
import * as koboApi from "./api";
import type { KoboDelivery, KoboReader, KoboSettings, KoboSetup } from "./contract";
import { ConfirmAction, RestoreStore, SetupInstructions, SyncOptions, ToneLine } from "./KoboParts";
import { SyncLine } from "./KoboReadersCard";
import { isMissingReader, koboFailure, useChoosePlace, useKoboKeys, useKoboPublish, useKoboReader, useKoboWrite, useRevoke, useSaveSettings } from "./queries";

const routeApi = getRouteApi("/account/devices/kobo/$readerId");

export function KoboReaderPage() {
  const { readerId } = routeApi.useParams();
  return <ReaderPage key={readerId} readerId={readerId} />;
}

function ReaderPage({ readerId }: { readerId: string }) {
  const { mode } = useServices();
  const reader = useKoboReader(readerId);
  const [revoked, setRevoked] = useState<string | null>(null);
  useDocumentTitle(reader.data?.name ? `${reader.data.name} · Devices` : "Kobo reader · Devices");
  const missing = reader.isError && isMissingReader(reader.error);
  const heading = revoked ? "Kobo connection revoked" : missing ? "Kobo reader" : (reader.data?.name ?? (reader.isError ? "Kobo reader" : "Loading reader"));
  return (
    <section className="account kobo-reader" aria-labelledby="kobo-reader-heading">
      <p className="people-back">
        <Link to="/account/$section" params={{ section: "devices" }} hash="kobo-readers">
          <span aria-hidden="true">← </span>Devices
        </Link>
      </p>
      <PageHeading id="kobo-reader-heading">{heading}</PageHeading>
      <p className="lede">Only you see and change these.</p>
      <AccountRail current="devices" />
      {mode !== "rails" ? (
        <EmptyState title="Kobo readers are not available here">
          <p>This server does not manage Kobo readers. Nothing was changed.</p>
        </EmptyState>
      ) : revoked ? (
        <div className="account-card" role="status">
          <p>{revoked}</p>
          <p>
            <Link to="/account/$section" params={{ section: "devices" }} hash="kobo-readers">
              Back to Devices
            </Link>
          </p>
        </div>
      ) : missing ? (
        <EmptyState title="This Kobo reader is not connected to your account">
          <p>It may have been revoked, or it belongs to someone else. Each person sees only their own readers.</p>
          <Link to="/account/$section" params={{ section: "devices" }} hash="kobo-readers" className="button">
            Your devices
          </Link>
        </EmptyState>
      ) : reader.data ? (
        <ReaderView reader={reader.data} onRevoked={setRevoked} />
      ) : reader.isError ? (
        <ErrorPanel error={reader.error} onRetry={() => void reader.refetch()} />
      ) : (
        <Loading label="Loading this Kobo reader…" />
      )}
    </section>
  );
}

function ReaderView({ reader, onRevoked }: { reader: KoboReader; onRevoked: (notice: string) => void }) {
  return (
    <div className="account-sections">
      <div className="kobo-reader-summary">
        <p className="request-meta">
          <span>{reader.mode_label}</span>
          <SyncLine at={reader.last_sync_at} first="Waiting for first sync from this reader" />
        </p>
        {reader.store_status ? <ToneLine notice={reader.store_status} testId="kobo-store-status" /> : null}
      </div>
      <SelectedBooks reader={reader} />
      <SettingsForm reader={reader} />
      <Connection reader={reader} onRevoked={onRevoked} />
    </div>
  );
}

function SelectedBooks({ reader }: { reader: KoboReader }) {
  const headingId = useId();
  const { said, say } = useSay();
  return (
    <section className="account-card" aria-labelledby={headingId}>
      <h2 id={headingId}>Selected books</h2>
      <p className="muted">Sync this Kobo over Wi-Fi to receive queued books. A download request does not confirm that the reader finished saving the book.</p>
      {reader.deliveries.length === 0 ? (
        <p>
          Open an acquired ebook in your <Link to="/library">library</Link> and choose Send to Kobo.
        </p>
      ) : (
        <ul className="kobo-deliveries">
          {reader.deliveries.map((delivery) => (
            <li key={delivery.entitlement_id} data-testid="kobo-delivery">
              <DeliveryRow reader={reader} delivery={delivery} say={say} />
            </li>
          ))}
        </ul>
      )}
      <Said said={said} />
    </section>
  );
}

function DeliveryTitle({ delivery }: { delivery: KoboDelivery }) {
  if (delivery.link?.kind === "library") {
    return (
      <Link to="/library/$publicationId" params={{ publicationId: delivery.link.publication_id }}>
        {delivery.title}
      </Link>
    );
  }
  if (delivery.link?.kind === "kobo_book") return <a href={delivery.link.href}>{delivery.title}</a>;
  return <>{delivery.title}</>;
}

function DeliveryRow({ reader, delivery, say }: { reader: KoboReader; delivery: KoboDelivery; say: (tone: "success" | "error", text: string) => void }) {
  const { api } = useServices();
  const keys = useKoboKeys();
  const client = useQueryClient();
  const choose = useChoosePlace(reader.id);
  const resend = useKoboWrite(
    (bookId: string) => koboApi.sendBook(api, reader.id, bookId),
    () => {
      void client.invalidateQueries({ queryKey: keys.reader(reader.id) });
    },
  );
  const row = useRef<HTMLDivElement>(null);
  const busy = choose.isPending || resend.isPending;
  const pick = (place: "kobo" | "shelfarr") =>
    choose.mutate(
      { delivery, place },
      {
        onSuccess: (answer) => {
          say(answer.kind === "chosen" ? "success" : "error", answer.kind === "chosen" ? answer.notice : answer.message);
          row.current?.focus();
        },
        onError: (error) => {
          void client.invalidateQueries({ queryKey: keys.reader(reader.id) });
          say("error", describeWriteFailure(error, "Shelfarr could not confirm whether the place was chosen. The list is being read again; check the book before choosing again."));
        },
      },
    );
  return (
    <div ref={row} className="kobo-delivery" tabIndex={-1} role="group" aria-label={delivery.title}>
      <div className="kobo-delivery-text">
        <p className="token-name">
          <DeliveryTitle delivery={delivery} />
        </p>
        <p className="request-meta">{delivery.status}</p>
        {delivery.edition ? (
          <p className="request-meta" data-testid="kobo-edition">
            {delivery.edition}
          </p>
        ) : null}
        {delivery.place ? <ToneLine notice={delivery.place} testId="kobo-place" /> : null}
        {delivery.outbound ? <ToneLine notice={delivery.outbound} testId="kobo-outbound" /> : null}
      </div>
      <div className="form-actions">
        {delivery.outbound?.choosable ? (
          <ConfirmAction label="Send Shelfarr place" question={`Move ${delivery.title} on ${reader.name} to the Shelfarr place at its next sync?`} confirmLabel="Send Shelfarr place" busy={busy} onConfirm={() => pick("shelfarr")} />
        ) : null}
        {delivery.place?.choosable ? (
          <ConfirmAction label="Use Kobo place" question={`Resume ${delivery.title} at the Kobo place in Shelfarr's web and mobile readers?`} confirmLabel="Use Kobo place" busy={busy} onConfirm={() => pick("kobo")} />
        ) : null}
        {delivery.send_again ? (
          <ConfirmAction
            label={
              <>
                Send again<span className="sr-only"> {delivery.title}</span>
              </>
            }
            question={delivery.send_again.confirmation}
            confirmLabel="Send again"
            busy={busy}
            onConfirm={() => {
              const bookId = delivery.send_again?.book_id;
              if (!bookId) return;
              resend.mutate(bookId, {
                onSuccess: (answer) => say("success", answer.notice),
                onError: (error) => {
                  void client.invalidateQueries({ queryKey: keys.reader(reader.id) });
                  say("error", koboFailure(error, "Shelfarr could not confirm whether the book was queued again. The list is being read again."));
                },
              });
            }}
          />
        ) : null}
      </div>
    </div>
  );
}

function settingsOf(reader: KoboReader): KoboSettings {
  return { store_coexistence: reader.store_coexistence, share_progress: reader.share_progress, receive_progress: reader.receive_progress };
}

function sameSettings(left: KoboSettings, right: KoboSettings): boolean {
  return left.store_coexistence === right.store_coexistence && left.share_progress === right.share_progress && left.receive_progress === right.receive_progress;
}

function SettingsForm({ reader }: { reader: KoboReader }) {
  const headingId = useId();
  const save = useSaveSettings(reader.id);
  const { said, say } = useSay();
  const [draft, setDraft] = useState<{ values: KoboSettings; version: string } | null>(null);
  const current = settingsOf(reader);
  const values = draft?.values ?? current;
  const dirty = draft !== null && !sameSettings(draft.values, current);
  const blocker = useBlocker({
    shouldBlockFn: ({ current: here, next }) => dirty && here.pathname !== next.pathname,
    enableBeforeUnload: () => dirty,
    withResolver: true,
  });

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (save.isPending) return;
    if (!dirty || !draft) {
      say("success", "Nothing to save: these are the reader's current settings.");
      return;
    }
    const sent = draft;
    save.mutate(
      { values: sent.values, version: sent.version },
      {
        onSuccess: (answer) => {
          if (answer.kind === "saved") {
            setDraft((now) => (now === sent ? null : now));
            say("success", answer.notice);
          } else if (answer.kind === "changed") {
            setDraft(null);
            say("error", "These settings were changed somewhere else while you were editing. Nothing was saved; the reader's current settings are shown. Choose again and save.");
          } else {
            say("error", `The settings were not saved. ${answer.messages.join(". ")}.`);
          }
        },
        onError: (error) => say("error", describeWriteFailure(error, "Shelfarr could not confirm whether the settings were saved. Reload the page to see the reader's settings.")),
      },
    );
  };

  return (
    <section className="account-card" aria-labelledby={headingId}>
      <h2 id={headingId}>Sync settings</h2>
      <form className="account-form" method="post" noValidate aria-labelledby={headingId} onSubmit={submit}>
        <SyncOptions values={values} disabled={save.isPending} onChange={(next) => setDraft((now) => ({ values: next, version: now?.version ?? reader.version }))} />
        {reader.placeholder_sign_in ? <p className="kobo-tone kobo-tone--warning">{reader.placeholder_sign_in}</p> : null}
        <p className="muted">Changes apply at the reader's next sync. The connection address stays the same.</p>
        <div className="settings-card-actions">
          <button type="submit" className="button button--primary" disabled={save.isPending} aria-busy={save.isPending}>
            {save.isPending ? "Saving…" : "Save settings"}
          </button>
          {dirty ? (
            <p className="unsaved-note">
              <span aria-hidden="true">● </span>Unsaved changes
            </p>
          ) : null}
        </div>
        <Said said={said} />
      </form>
      {blocker.status === "blocked" ? <LeaveDialog count={1} onStay={blocker.reset} onLeave={blocker.proceed} /> : null}
    </section>
  );
}

function Connection({ reader, onRevoked }: { reader: KoboReader; onRevoked: (notice: string) => void }) {
  const headingId = useId();
  const heading = useRef<HTMLHeadingElement>(null);
  const { api } = useServices();
  const publish = useKoboPublish();
  const keys = useKoboKeys();
  const client = useQueryClient();
  const revoke = useRevoke(reader.id);
  const { said, say } = useSay();
  const [setup, setSetup] = useState<KoboSetup | null>(null);
  const [making, setMaking] = useState(false);
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  const makeAddress = async () => {
    if (making) return;
    setMaking(true);
    try {
      const answer = await koboApi.newAddress(api, reader.id, reader.version);
      if (!mounted.current || !publish.active()) return;
      if (answer.kind === "created") {
        client.setQueryData<KoboReader>(keys.reader(reader.id), (now) => (now ? { ...now, ...answer.setup.reader } : now));
        publish.refresh();
        setSetup(answer.setup);
      } else {
        publish.reader(answer.reader);
        say("error", "This reader was changed somewhere else, so no new address was made and the current one still works. Review the reader, then make a new address again if you need one.");
      }
    } catch (error) {
      if (!mounted.current) return;
      publish.lost(error);
      void client.invalidateQueries({ queryKey: keys.reader(reader.id) });
      say("error", describeWriteFailure(error, "Shelfarr could not confirm whether a new address was made. If the reader stops syncing, make a new address and update the reader."));
    } finally {
      if (mounted.current) setMaking(false);
    }
  };

  return (
    <section className="account-card" aria-labelledby={headingId}>
      <h2 id={headingId} ref={heading} tabIndex={-1}>
        Connection
      </h2>
      {setup ? (
        <SetupInstructions
          setup={setup.setup}
          name={setup.reader.name}
          storeCoexistence={setup.reader.store_coexistence}
          done={
            <button
              type="button"
              className="button button--primary"
              onClick={() => {
                setSetup(null);
                heading.current?.focus();
              }}
            >
              I updated the reader
            </button>
          }
        />
      ) : (
        <>
          <p className="muted">
            This reader reaches Shelfarr at <span className="secret">{reader.base_url}</span>. Making a new address disables the previous one; update the reader's configuration afterward. Revoking this connection keeps books already on the reader.
          </p>
          <RestoreStore storeEndpoint={reader.store_endpoint} />
          <div className="form-actions">
            <ConfirmAction
              label="Make a new connection address"
              question="Make a new address? The current one stops working at once, so this reader cannot sync until you edit its configuration."
              confirmLabel={making ? "Making address…" : "Make a new address"}
              busy={making}
              onConfirm={() => void makeAddress()}
            />
          </div>
          <div className="form-actions">
            <RemoveZone
              label="Revoke connection"
              confirmLabel={revoke.isPending ? "Revoking…" : "Revoke connection"}
              question="Revoke this Kobo connection? The reader will stop syncing with Shelfarr."
              busy={revoke.isPending}
              onRemove={() =>
                revoke.mutate(reader.version, {
                  onSuccess: (answer) => {
                    if (answer.kind === "revoked") onRevoked(answer.notice);
                    else say("error", "This reader was changed somewhere else, so it was not revoked. Review it, then revoke it again if you still want to.");
                  },
                  onError: (error) => {
                    if (isMissingReader(error)) onRevoked("This Kobo connection was already revoked. Books already on the reader are kept.");
                    else say("error", describeWriteFailure(error, "Shelfarr could not confirm whether the connection was revoked. Reload the page to see whether it is still connected."));
                  },
                })
              }
            />
          </div>
        </>
      )}
      <Said said={said} />
    </section>
  );
}
