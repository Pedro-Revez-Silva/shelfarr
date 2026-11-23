import { Link, useLocation, useNavigate } from "@tanstack/react-router";
import { useEffect, useId, useRef, useState, type FormEvent, type ReactNode } from "react";
import type { RequestActions, RequestCopies, RequestDetail, RequestWithdrawalOffer, StoreOffer } from "../contract";
import { useCancelTrackedRequest, useChooseRequestCopy, useManualLink, useRemoveRequest, useRetryRequest, useSearchRequestAgain, useWithdrawRequest } from "../requestActions";
import { CopyTable, focusLeftThePage, keepsFocus } from "./CopyTable";
import { actionFailure, Time } from "./requestText";

type Pending = { isPending: boolean; isError: boolean; error: unknown };

export function RequestTools({ request, admin }: { request: RequestDetail; admin: boolean }) {
  const actions = request.actions;
  if (!actions) return null;
  return (
    <>
      {request.store_offers && request.store_offers.length > 0 ? <StoreOffers offers={request.store_offers} requestId={request.id} uploads={actions.upload_url !== null} /> : null}
      <MainActions request={request} actions={actions} admin={admin} />
      {admin ? <Inspector request={request} actions={actions} /> : null}
    </>
  );
}

function MainActions({ request, actions, admin }: { request: RequestDetail; actions: RequestActions; admin: boolean }) {
  const retry = useRetryRequest(request.id);
  const search = useSearchRequestAgain(request.id);
  const searchHere = admin && actions.search_again && !request.copies;
  const memberUpload = !admin && actions.upload_url !== null && (request.store_offers ?? []).length === 0;
  const memberRemoval = !admin && actions.remove === "delete_history" ? actions.remove : null;
  const withdraw = useWithdrawRequest(request.id);
  const withdrawal = admin ? null : actions.withdraw;
  const shown = request.book_page || actions.cancel || actions.download_url || memberUpload || memberRemoval || withdrawal || withdraw.isError || (admin && (actions.retry || searchHere));
  if (!shown) return null;
  return (
    <div className="copy-actions request-actions">
      {request.book_page ? (
        <Link to="/books/$source/$sourceId" params={{ source: request.book_page.source, sourceId: request.book_page.id }} className="button">
          Open the Book page<span className="sr-only"> for {request.title}</span>
        </Link>
      ) : null}
      {actions.download_url ? (
        <a className="button" href={actions.download_url} download>
          Download the file<span className="sr-only"> of {request.title}</span>
        </a>
      ) : null}
      {admin && actions.retry ? <ActionButton label="Retry now" busy="Retrying…" state={retry} onClick={() => retry.mutate(undefined)} /> : null}
      {searchHere ? <ActionButton label="Search again" busy="Searching…" state={search} onClick={() => search.mutate(undefined)} /> : null}
      {actions.cancel ? <CancelTracked request={request} /> : null}
      {withdrawal ? <WithdrawRequest offer={withdrawal} withdraw={withdraw} /> : null}
      {memberUpload ? (
        <Link className="button" to="/library/uploads" search={{ request: request.id }}>
          Upload a file for this request
        </Link>
      ) : null}
      {memberRemoval ? <RemoveRequest request={request} mode={memberRemoval} /> : null}
      {retry.data?.message ? <p role="status">{retry.data.message}</p> : null}
      {retry.isError ? <Failure error={retry.error} fallback="The request could not be retried. Nothing was changed." /> : null}
      {search.isError ? <Failure error={search.error} fallback="The search could not be started. Nothing was changed." /> : null}
      {withdraw.isError ? <Failure error={withdraw.error} fallback="The request could not be removed. Nothing was changed." /> : null}
    </div>
  );
}

function ActionButton({ label, busy, state, onClick }: { label: string; busy: string; state: Pending; onClick: () => void }) {
  return (
    <button type="button" className="button button--subtle" aria-disabled={state.isPending ? true : undefined} onClick={() => (state.isPending ? undefined : onClick())}>
      {state.isPending ? busy : label}
    </button>
  );
}

function Failure({ error, fallback }: { error: unknown; fallback: string }) {
  return (
    <p className="field-error" role="alert">
      {actionFailure(error, fallback)}
    </p>
  );
}

function Confirm({ ask, question, confirm, busy, state, onConfirm, children }: { ask: string; question: string; confirm: string; busy: string; state: Pending; onConfirm: () => void; children?: ReactNode }) {
  const [asking, setAsking] = useState(false);
  const keep = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (asking) keep.current?.focus();
  }, [asking]);
  if (!asking) {
    return (
      <button type="button" className="button button--subtle" onClick={() => setAsking(true)}>
        {ask}
      </button>
    );
  }
  return (
    <span className="cancel-confirm" role="group" aria-label={question}>
      <span>{question}</span>
      {children}
      <button type="button" className="button button--danger" aria-disabled={state.isPending ? true : undefined} onClick={() => (state.isPending ? undefined : onConfirm())}>
        {state.isPending ? busy : confirm}
      </button>
      <button ref={keep} type="button" className="button button--subtle" onClick={() => setAsking(false)}>
        Keep it
      </button>
    </span>
  );
}

function CancelTracked({ request }: { request: RequestDetail }) {
  const cancel = useCancelTrackedRequest(request.id);
  return (
    <>
      <Confirm ask="Cancel request" question="Cancel this request? If a download is running, it is stopped and its files are deleted from the download client." confirm="Yes, cancel it" busy="Cancelling…" state={cancel} onConfirm={() => cancel.mutate(undefined)} />
      {cancel.isError ? <Failure error={cancel.error} fallback="The request could not be cancelled. Nothing was changed." /> : null}
    </>
  );
}

function WithdrawRequest({ offer, withdraw }: { offer: RequestWithdrawalOffer; withdraw: ReturnType<typeof useWithdrawRequest> }) {
  const navigate = useNavigate();
  const [askedOn, setAskedOn] = useState<string | null>(null);
  const [removeTorrent, setRemoveTorrent] = useState(false);
  const ask = useRef<HTMLButtonElement>(null);
  const keep = useRef<HTMLButtonElement>(null);
  const wasAsking = useRef(false);
  const questionId = useId();
  const consequenceId = useId();
  const torrentId = useId();
  const torrentHintId = useId();
  const asking = askedOn !== null && (askedOn === offer.revision || withdraw.isPending);
  const lapsed = askedOn !== null && !asking;
  const torrent = offer.torrents === 1 ? "the torrent" : `its ${offer.torrents} torrents`;
  const choosesTorrent = offer.torrents > 0 && removeTorrent;

  useEffect(() => {
    if (asking) keep.current?.focus();
    else if (wasAsking.current && focusLeftThePage()) ask.current?.focus();
    wasAsking.current = asking;
  }, [asking]);

  const open = () => {
    withdraw.reset();
    setRemoveTorrent(false);
    setAskedOn(offer.revision);
  };
  const confirm = () => {
    if (withdraw.isPending) return;
    withdraw.mutate(
      { expected_revision: offer.revision, remove_torrent: choosesTorrent },
      { onSuccess: (answer) => (answer.request.status === "removed" ? void navigate({ to: "/requests", replace: true }) : undefined) },
    );
  };

  return (
    <>
      {asking ? (
        <div className="cancel-confirm withdraw-confirm" role="group" aria-labelledby={questionId} aria-describedby={consequenceId}>
          <p id={questionId}>Remove this request?</p>
          <div id={consequenceId} className="withdraw-consequence">
            <p>It leaves your requests and Shelfarr stops working on it. Files already in the library stay.</p>
            {offer.torrents > 0 ? (
              <div className="check-field">
                <input id={torrentId} type="checkbox" checked={removeTorrent} aria-describedby={torrentHintId} onChange={(event) => setRemoveTorrent(event.currentTarget.checked)} />
                <label htmlFor={torrentId}>Also remove {torrent} from the download client</label>
                <p id={torrentHintId} className="field-hint">
                  {choosesTorrent
                    ? `Shelfarr asks the download client to remove ${torrent}. The files already downloaded stay on disk. If the client can't be reached, the request is still removed and ${torrent} stays.`
                    : `The download client keeps ${torrent} and the files already downloaded.`}
                </p>
              </div>
            ) : (
              <p>No download client is contacted.</p>
            )}
          </div>
          <span className="withdraw-buttons">
            <button type="button" className="button button--danger" aria-disabled={withdraw.isPending ? true : undefined} onClick={confirm}>
              {withdraw.isPending ? "Removing…" : choosesTorrent ? `Yes, remove it and ${torrent}` : "Yes, remove it"}
            </button>
            <button ref={keep} type="button" className="button button--subtle" onClick={() => setAskedOn(null)}>
              Keep it
            </button>
          </span>
        </div>
      ) : (
        <button ref={ask} type="button" className="button button--subtle" onClick={open}>
          Remove request
        </button>
      )}
      {lapsed && !withdraw.isError ? <p role="status">This request changed while you were deciding. Check what removing it does now and ask again.</p> : null}
    </>
  );
}

function RemoveRequest({ request, mode }: { request: RequestDetail; mode: NonNullable<RequestActions["remove"]> }) {
  const remove = useRemoveRequest(request.id);
  const navigate = useNavigate();
  const finished = request.status === "completed";
  const label = finished ? "Delete request history" : "Remove request";
  const question = finished ? "Delete this request's history? Library files are kept." : "Remove this request? Its download is stopped in the download client; files outside the library are kept.";
  return (
    <>
      <Confirm
        ask={label}
        question={question}
        confirm={finished ? "Yes, delete it" : "Yes, remove it"}
        busy="Removing…"
        state={remove}
        onConfirm={() => remove.mutate(undefined, { onSuccess: () => void navigate({ to: "/requests", replace: true }) })}
      />
      {remove.isError ? <Failure error={remove.error} fallback="The request could not be removed. Nothing was changed." /> : null}
      {mode === "delete_history" && request.library ? <p className="request-meta">To request this book again later, an administrator removes it from the library first.</p> : null}
    </>
  );
}

function StoreOffers({ offers, requestId, uploads }: { offers: StoreOffer[]; requestId: string; uploads: boolean }) {
  const headingId = useId();
  return (
    <section className="store-offers" aria-labelledby={headingId}>
      <h2 id={headingId}>Buy it DRM-free</h2>
      <p className="request-note">Checkout, account details and payment stay with the seller. Prices and availability can change at checkout.{uploads ? " After buying, upload the EPUB or PDF to this request." : " After buying, ask an administrator to import the file into this request."}</p>
      <ul className="offer-list">
        {offers.map((offer) => (
          <li key={offer.id} className="offer">
            <div>
              <p className="offer-title">{offer.title}</p>
              <p className="request-meta">
                <span>{offer.provider}</span>
                <span>{offer.drm}</span>
                {offer.price ? <span>{offer.price}</span> : null}
                {offer.formats.length ? <span>{offer.formats.join(", ")}</span> : null}
                {offer.language ? <span>{offer.language}</span> : null}
                {offer.quoted_at ? (
                  <span>
                    Checked <Time iso={offer.quoted_at} relative />
                  </span>
                ) : null}
              </p>
            </div>
            <a className="button button--primary" href={offer.url} target="_blank" rel="noopener noreferrer">
              View and buy at {offer.provider}
              <span className="sr-only"> (opens in a new tab)</span>
            </a>
          </li>
        ))}
      </ul>
      {uploads ? (
        <Link className="button button--subtle" to="/library/uploads" search={{ request: requestId }}>
          Upload after buying
        </Link>
      ) : null}
    </section>
  );
}

function Inspector({ request, actions }: { request: RequestDetail; actions: RequestActions }) {
  const copies = request.copies;
  const linked = useLocation({ select: (location) => location.hash === "copies" });
  return (
    <section className="request-inspector" aria-label="Administrator tools">
      {copies ? (
        <Section id="copies" title={`Copies (${copies.candidates.length})`} open={copies.selectable || linked} target={linked}>
          <Copies request={request} copies={copies} actions={actions} />
        </Section>
      ) : null}
      {actions.manual_download || actions.upload_url ? (
        <Section id="add-link" title="Add a link or file">
          {actions.manual_download ? <ManualLink requestId={request.id} replaces={actions.replaces_library_file} /> : null}
          {actions.upload_url ? (
            <p>
              <Link to="/library/uploads" search={{ request: request.id }}>
                Upload a file for this request
              </Link>
            </p>
          ) : null}
        </Section>
      ) : null}
      <Section id="diagnostics" title="Diagnostics">
        <dl className="request-facts">
          {request.attention_reason ? (
            <div>
              <dt>Issue</dt>
              <dd>{request.attention_reason}</dd>
            </div>
          ) : null}
          <div>
            <dt>Attempts</dt>
            <dd>{request.retry_count ?? 0}</dd>
          </div>
        </dl>
        {request.events && request.events.length > 0 ? (
          <ol className="event-list">
            {request.events.map((event, index) => (
              <li key={index}>
                <span className={`badge badge--event badge--${event.level}`}>{event.title}</span> <Time iso={event.at} relative />
                {event.message ? <p className="request-meta">{event.message}</p> : null}
              </li>
            ))}
          </ol>
        ) : (
          <p className="request-note">No events recorded for this request.</p>
        )}
      </Section>
      {actions.remove === "admin_remove" ? (
        <Section id="remove" title="Remove">
          <RemoveRequest request={request} mode="admin_remove" />
        </Section>
      ) : null}
    </section>
  );
}

function Section({ id, title, open = false, target = false, children }: { id: string; title: string; open?: boolean; target?: boolean; children: ReactNode }) {
  const details = useRef<HTMLDetailsElement>(null);
  const summary = useRef<HTMLElement>(null);
  useEffect(() => {
    if (open && details.current) details.current.open = true;
  }, [open]);
  useEffect(() => {
    if (!target) return;
    summary.current?.scrollIntoView({ block: "start" });
    summary.current?.focus({ preventScroll: true });
  }, [target]);
  return (
    <details ref={details} className="inspector-section" id={id}>
      <summary ref={summary}>{title}</summary>
      <div className="inspector-body">{children}</div>
    </details>
  );
}

const FOCUS_FALLBACKS = ["button[type=submit]", ".copy-table-wrap", ".copies-empty"];

function Copies({ request, copies, actions }: { request: RequestDetail; copies: RequestCopies; actions: RequestActions }) {
  const search = useSearchRequestAgain(request.id);
  const choose = useChooseRequestCopy(request.id);
  const replaces = actions.replaces_library_file;
  const revision = copies.revision;
  const choice = {
    mutate: (resultId: string) => choose.mutate(revision === null ? { result_id: resultId } : { result_id: resultId, expected_revision: revision, replace_library_file: replaces }),
    isPending: choose.isPending,
    isError: choose.isError,
    error: choose.error,
  };
  const count = copies.candidates.length;
  const locked = revision === null && !copies.selectable;
  const section = useRef<HTMLDivElement>(null);
  const holdsFocus = useRef(false);
  useEffect(() => {
    if (!holdsFocus.current || !focusLeftThePage()) return;
    const target = FOCUS_FALLBACKS.map((selector) => section.current?.querySelector<HTMLElement>(selector)).find(Boolean);
    target?.focus();
  });
  return (
    <div
      ref={section}
      className="copies"
      onFocus={() => {
        holdsFocus.current = true;
      }}
      onBlur={(event) => {
        holdsFocus.current = keepsFocus(event);
      }}
    >
      <div className="copies-heading">
        <p className="request-meta">
          {copies.looking_for ? `Looking for ${copies.looking_for} · ` : ""}
          {count === 1 ? "1 copy found" : `${count} copies found`}, best first
        </p>
        {actions.search_again ? <ActionButton label="Search again" busy="Searching…" state={search} onClick={() => search.mutate(undefined)} /> : null}
      </div>
      {copies.search_blocked ? <p className="request-note">{copies.search_blocked}</p> : null}
      {search.isError ? <Failure error={search.error} fallback="The search could not be started. Nothing was changed." /> : null}
      <div role="status">{search.isSuccess ? <p className="form-success">Searching again. Copies found by this search appear here.</p> : null}</div>
      {count > 0 ? (
        <CopyTable copies={copies.candidates} choose={choice} preselect={false} replaces={replaces} lookingFor={copies.looking_for} stateKey={revision} locked={locked} />
      ) : (
        <>
          <p className="request-note copies-empty" tabIndex={-1}>
            No copies found yet. The search may still be running.
          </p>
          {choose.isError ? <Failure error={choose.error} fallback="The choice could not be sent. Nothing was changed." /> : null}
        </>
      )}
      <div role="status">{choose.isSuccess ? <p className="form-success">Download queued. This page updates as it goes.</p> : null}</div>
    </div>
  );
}

function ManualLink({ requestId, replaces }: { requestId: string; replaces: boolean }) {
  const add = useManualLink(requestId);
  const [kind, setKind] = useState<"magnet" | "nzb">("magnet");
  const [url, setUrl] = useState("");
  const [replace, setReplace] = useState(false);
  const [blank, setBlank] = useState(false);
  const ids = { kind: useId(), url: useId(), error: useId(), hint: useId() };
  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (add.isPending) return;
    if (url.trim() === "") {
      setBlank(true);
      return;
    }
    setBlank(false);
    add.mutate({ kind, url: url.trim(), replace_library_file: replace }, { onSuccess: () => setUrl("") });
  };
  return (
    <form className="account-form manual-link" onSubmit={submit} noValidate>
      <fieldset>
        <legend>Link type</legend>
        <label>
          <input type="radio" name="kind" value="magnet" checked={kind === "magnet"} onChange={() => setKind("magnet")} /> Magnet link (sent to the torrent client)
        </label>
        <label>
          <input type="radio" name="kind" value="nzb" checked={kind === "nzb"} onChange={() => setKind("nzb")} /> NZB address (sent to the Usenet client)
        </label>
      </fieldset>
      <div className="field">
        <label htmlFor={ids.url}>{kind === "magnet" ? "Magnet link" : "NZB address"}</label>
        <p id={ids.hint} className="field-hint">
          If a download is already running for this request, this one replaces it.
        </p>
        <input
          id={ids.url}
          type={kind === "magnet" ? "text" : "url"}
          inputMode="url"
          autoComplete="off"
          spellCheck={false}
          value={url}
          placeholder={kind === "magnet" ? "magnet:?xt=urn:btih:…" : "https://"}
          aria-invalid={blank}
          aria-describedby={blank ? `${ids.hint} ${ids.error}` : ids.hint}
          onChange={(event) => {
            setUrl(event.target.value);
            setBlank(false);
          }}
        />
        {blank ? (
          <p id={ids.error} className="field-error">
            <span aria-hidden="true">⚠ </span>Paste a link first.
          </p>
        ) : null}
      </div>
      {replaces ? (
        <label className="check">
          <input type="checkbox" checked={replace} onChange={(event) => setReplace(event.target.checked)} /> Replace the library file once this download imports. A failed download leaves the current file unchanged.
        </label>
      ) : null}
      <div className="form-actions">
        <button type="submit" className="button button--primary" aria-disabled={add.isPending ? true : undefined}>
          {add.isPending ? "Sending…" : kind === "magnet" ? "Add magnet link" : "Add NZB address"}
        </button>
      </div>
      <div role="status">{add.isSuccess ? <p className="form-success">Queued for download. This page updates as it goes.</p> : null}</div>
      {add.isError ? <Failure error={add.error} fallback="The link could not be queued. Nothing was changed." /> : null}
    </form>
  );
}
