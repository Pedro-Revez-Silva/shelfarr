import { useId, useRef, useState, type FormEvent } from "react";
import type { BookCopy } from "../contract";
import { formatBytes } from "./DetailsPage";
import { actionFailure } from "./requestText";

function firstChoice(copies: BookCopy[]): string {
  return copies.find((copy) => copy.downloadable && !copy.skipped)?.id ?? copies.find((copy) => copy.downloadable)?.id ?? "";
}

export type CopyChoice = { mutate: (resultId: string) => void; isPending: boolean; isError: boolean; error: unknown };

export function CopyTable({ copies, choose }: { copies: BookCopy[]; choose: CopyChoice }) {
  const [chosen, setChosen] = useState(() => firstChoice(copies));
  const [missing, setMissing] = useState(false);
  const captionId = useId();
  const errorId = useId();
  const firstChoosable = useRef<HTMLInputElement>(null);
  const firstChoosableId = copies.find((copy) => copy.downloadable)?.id;
  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (choose.isPending) return;
    if (!copies.some((copy) => copy.id === chosen && copy.downloadable)) {
      setMissing(true);
      firstChoosable.current?.focus();
      return;
    }
    setMissing(false);
    choose.mutate(chosen);
  };
  return (
    <form className="copy-form" onSubmit={submit} noValidate>
      <div className="copy-table-wrap" role="region" aria-labelledby={captionId} tabIndex={0}>
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
                    disabled={!copy.downloadable}
                    onChange={() => {
                      setChosen(copy.id);
                      setMissing(false);
                    }}
                  />
                </td>
                <th scope="row">
                  <label htmlFor={`copy-${copy.id}`}>{copy.title}</label>
                  {copy.skipped ? <span className="copy-flag"> · skipped before</span> : null}
                  {!copy.downloadable ? <span className="copy-flag"> · no download link</span> : null}
                </th>
                <td data-label="Format">{copy.format ?? "Unknown"}</td>
                <td data-label="Size">{copy.size_bytes !== null ? formatBytes(copy.size_bytes) : "Unknown"}</td>
                <td data-label="Language">{copy.language ?? "Unknown"}</td>
                <td data-label="Source">{copy.source}</td>
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
      <div className="copy-actions">
        <button type="submit" className="button button--primary button--large" aria-disabled={choose.isPending ? true : undefined}>
          {choose.isPending ? "Sending…" : "Download this copy"}
        </button>
      </div>
      {choose.isError ? (
        <p className="field-error" role="alert">
          {actionFailure(choose.error, "The choice could not be sent. Nothing was changed.")}
        </p>
      ) : null}
    </form>
  );
}
