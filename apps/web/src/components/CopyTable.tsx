import { useEffect, useId, useRef, useState, type FocusEvent, type FormEvent } from "react";
import type { BookCopy, CopyChoiceKind, CopyDetails } from "../contract";
import { formatBytes } from "./DetailsPage";
import { actionFailure } from "./requestText";

type ListedCopy = BookCopy & { details?: CopyDetails | null };
type ChoosableKind = Extract<CopyChoiceKind, "select" | "select_instead" | "retry_anyway">;

const SUBMIT_LABELS: Record<ChoosableKind, string> = {
  select: "Download this copy",
  select_instead: "Download this copy instead",
  retry_anyway: "Try this copy again anyway",
};

const REPLACEMENT_PROMPT = "Replace the existing library file? The current file stays until the new download imports successfully. A failed download leaves it unchanged.";

function choosableKind(copy: ListedCopy): ChoosableKind | null {
  if (copy.details === undefined) return copy.downloadable ? "select" : null;
  const choice = copy.details?.choice ?? null;
  if (choice === null) return fallbackKind(copy);
  return choice === "select" || choice === "select_instead" || choice === "retry_anyway" ? choice : null;
}

function isChosen(copy: ListedCopy): boolean {
  const choice = copy.details?.choice ?? null;
  return choice === null ? copy.details !== undefined && copy.state === "selected" : choice === "selected";
}


function fallbackKind(copy: BookCopy): ChoosableKind | null {
  if (!copy.downloadable || copy.state === "selected") return null;
  if (copy.skipped) return "retry_anyway";
  return copy.state === "rejected" ? "select_instead" : "select";
}

function firstChoice(copies: ListedCopy[]): ListedCopy | undefined {
  return copies.find((copy) => choosableKind(copy) && !copy.skipped) ?? copies.find((copy) => choosableKind(copy));
}

function pickOf(copy: ListedCopy, stateKey: string | null): string {
  return JSON.stringify([stateKey, copy]);
}

export type CopyChoice = { mutate: (resultId: string) => void; isPending: boolean; isError: boolean; error: unknown };

export function CopyTable({
  copies,
  choose,
  preselect = true,
  replaces = false,
  lookingFor = null,
  stateKey = null,
  locked = false,
}: {
  copies: ListedCopy[];
  choose: CopyChoice;
  preselect?: boolean;
  replaces?: boolean;
  lookingFor?: string | null;
  stateKey?: string | null;
  locked?: boolean;
}) {
  const [picked, setPicked] = useState<string | null>(null);
  const [missing, setMissing] = useState(false);
  const [askedFor, setAskedFor] = useState<{ id: string; stateKey: string | null } | null>(null);
  const captionId = useId();
  const errorId = useId();
  const firstChoosable = useRef<HTMLInputElement>(null);
  const tableRegion = useRef<HTMLDivElement>(null);
  const submitButton = useRef<HTMLButtonElement>(null);
  const keepButton = useRef<HTMLButtonElement>(null);
  const kindOf = (copy: ListedCopy) => (locked ? null : choosableKind(copy));
  const detailed = copies.some((copy) => copy.details);
  const firstChoosableId = copies.find((copy) => kindOf(copy))?.id;
  const suggested = preselect && !locked ? firstChoice(copies) : undefined;
  const chosenCopy = picked === null ? suggested : copies.find((copy) => pickOf(copy, stateKey) === picked && kindOf(copy));
  const chosen = chosenCopy?.id ?? "";
  const chosenKind = chosenCopy ? kindOf(chosenCopy) : null;
  const confirming = askedFor !== null && askedFor.id === chosen && askedFor.stateKey === stateKey;
  const holdsFocus = useRef(false);
  useEffect(() => {
    if (confirming) keepButton.current?.focus();
  }, [confirming]);
  useEffect(() => {
    if (holdsFocus.current && focusLeftThePage()) (submitButton.current ?? tableRegion.current)?.focus();
  });
  const noteFocus = () => {
    holdsFocus.current = true;
  };
  const noteBlur = (event: FocusEvent<HTMLFormElement>) => {
    const next = event.relatedTarget instanceof Node ? event.relatedTarget : null;
    if (!event.currentTarget.contains(next) && event.target.isConnected) holdsFocus.current = false;
  };
  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (choose.isPending) return;
    if (!chosen) {
      setMissing(true);
      firstChoosable.current?.focus();
      return;
    }
    setMissing(false);
    if (replaces) {
      setAskedFor({ id: chosen, stateKey });
      return;
    }
    choose.mutate(chosen);
  };
  const confirmReplacement = () => {
    setAskedFor(null);
    if (confirming) choose.mutate(chosen);
    submitButton.current?.focus();
  };
  const keepFile = () => {
    setAskedFor(null);
    submitButton.current?.focus();
  };
  return (
    <form className="copy-form" onSubmit={submit} onFocus={noteFocus} onBlur={noteBlur} noValidate>
      <div ref={tableRegion} className="copy-table-wrap" role="region" aria-labelledby={captionId} tabIndex={0}>
        <table className="copy-table" aria-describedby={missing ? errorId : undefined}>
          <caption id={captionId} className="sr-only">
            Copies found; choose one to download
          </caption>
          <thead>
            <tr>
              <th scope="col">
                <span className="sr-only">Choose</span>
              </th>
              <th scope="col">Copy</th>
              <th scope="col">Format</th>
              <th scope="col">Size</th>
              <th scope="col">Language</th>
              <th scope="col">Source</th>
              {detailed ? <th scope="col">Score</th> : null}
              {detailed ? <th scope="col">Peers</th> : null}
            </tr>
          </thead>
          <tbody>
            {copies.map((copy) => (
              <tr key={copy.id} className={chosen === copy.id ? "copy-row copy-row--chosen" : "copy-row"}>
                <td className="copy-choice">
                  <input
                    ref={copy.id === firstChoosableId ? firstChoosable : undefined}
                    type="radio"
                    id={`copy-${copy.id}`}
                    name="copy"
                    value={copy.id}
                    checked={chosen === copy.id}
                    disabled={!kindOf(copy)}
                    onChange={() => {
                      setPicked(pickOf(copy, stateKey));
                      setMissing(false);
                      setAskedFor(null);
                    }}
                  />
                </td>
                <th scope="row">
                  <label htmlFor={`copy-${copy.id}`}>{copy.title}</label>
                  {isChosen(copy) ? <span className="copy-flag copy-flag--chosen"> · chosen</span> : null}
                  {copy.skipped ? <span className="copy-flag"> · skipped before</span> : null}
                  {copy.details?.choice === "skipped" ? <span className="copy-flag"> · skipped</span> : null}
                  {!copy.downloadable ? <span className="copy-flag"> · no download link</span> : null}
                  {copy.details ? <CopyFacts title={copy.title} details={copy.details} /> : null}
                </th>
                <td data-label="Format">{copy.format ?? "Unknown"}</td>
                <td data-label="Size">{copy.size_bytes !== null ? formatBytes(copy.size_bytes) : "Unknown"}</td>
                <td data-label="Language">
                  {copy.language ?? "Unknown"}
                  {copy.details && !copy.details.language_matches && lookingFor ? <span className="copy-flag copy-flag--warn"> · not {lookingFor}</span> : null}
                </td>
                <td data-label="Source">{copy.source}</td>
                {detailed ? <td data-label="Score">{copy.details ? scoreText(copy.details) : "Unknown"}</td> : null}
                {detailed ? <td data-label="Peers">{copy.details ? peersText(copy.details) : "Not listed"}</td> : null}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {missing ? (
        <p id={errorId} className="field-error" role="alert">
          <span aria-hidden="true">⚠ </span>Choose one copy that can be downloaded first.
        </p>
      ) : null}
      {firstChoosableId ? (
        <div className="copy-actions">
          <button ref={submitButton} type="submit" className="button button--primary button--large" aria-disabled={choose.isPending ? true : undefined}>
            {choose.isPending ? "Sending…" : SUBMIT_LABELS[chosenKind ?? "select"]}
          </button>
          {confirming ? (
            <span className="cancel-confirm" role="group" aria-label={REPLACEMENT_PROMPT}>
              <span>{REPLACEMENT_PROMPT}</span>
              <button type="button" className="button button--danger" onClick={confirmReplacement}>
                Yes, replace the file
              </button>
              <button ref={keepButton} type="button" className="button button--subtle" onClick={keepFile}>
                Keep the current file
              </button>
            </span>
          ) : null}
        </div>
      ) : (
        <p className="request-note">None of these copies can be downloaded now.</p>
      )}
      {choose.isError ? (
        <p className="field-error" role="alert">
          {actionFailure(choose.error, "The choice could not be sent. Nothing was changed.")}
        </p>
      ) : null}
    </form>
  );
}

export function focusLeftThePage(): boolean {
  return document.activeElement === null || document.activeElement === document.body;
}

function scoreText(details: CopyDetails): string {
  if (details.score === null) return "Unknown";
  return details.high_confidence ? `${details.score}% (high)` : `${details.score}%`;
}

function peersText(details: CopyDetails): string {
  if (details.seeders === null && details.leechers === null) return "Not listed";
  return [details.seeders !== null ? `${details.seeders} seeding` : null, details.leechers !== null ? `${details.leechers} leeching` : null].filter(Boolean).join(", ");
}

function signed(value: number): string {
  return value > 0 ? `+${value}` : `−${Math.abs(value)}`;
}

function CopyFacts({ title, details }: { title: string; details: CopyDetails }) {
  const facts: string[] = [];
  if (details.indexer) facts.push(details.indexer);
  if (details.structure) facts.push(details.structure === "single_file" ? "Single file" : "Multi-file");
  if (details.bitrate_kbps !== null) facts.push(`${details.bitrate_kbps} kbps`);
  if (details.preference_adjustment !== 0) facts.push(`Preference ${signed(details.preference_adjustment)}`);
  if (details.size_limit) facts.push(details.size_limit.explanation ? `${details.size_limit.label}: ${details.size_limit.explanation}` : details.size_limit.label);
  if (details.manual_review) facts.push("Manual review");
  if (details.blocklist_reason) facts.push(`Skipped because: ${details.blocklist_reason}`);
  if (facts.length === 0 && !details.info_url) return null;
  return (
    <ul className="copy-facts">
      {facts.map((fact) => (
        <li key={fact}>{fact}</li>
      ))}
      {details.info_url ? (
        <li>
          <a href={details.info_url} target="_blank" rel="noopener noreferrer">
            Release page<span className="sr-only"> for {title} (opens in a new tab)</span>
          </a>
        </li>
      ) : null}
    </ul>
  );
}
