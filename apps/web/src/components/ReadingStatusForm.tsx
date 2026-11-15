import { useId, useState, type FormEvent } from "react";
import { failureKind } from "../api/errors";
import { readingStatuses, type PublicationDetail, type ReadingStatus } from "../contract";
import { useReadingStatus } from "../queries";

const LABELS: Record<ReadingStatus, string> = { unread: "Unread", in_progress: "Reading", finished: "Finished" };

export function ReadingStatusForm({ publication }: { publication: PublicationDetail }) {
  const selectId = useId();
  const [draft, setDraft] = useState<ReadingStatus | null>(null);
  const mutation = useReadingStatus(publication.id);
  const value = draft ?? publication.reading_status;
  const dirty = value !== publication.reading_status;

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    mutation.mutate(value, { onSuccess: () => setDraft(null) });
  }

  return (
    <form className="status-form" onSubmit={submit}>
      <label htmlFor={selectId}>Reading status</label>
      <div className="status-row">
        <select id={selectId} value={value} onChange={(event) => setDraft(readingStatuses.find((status) => status === event.target.value) ?? null)}>
          {readingStatuses.map((status) => (
            <option key={status} value={status}>
              {LABELS[status]}
            </option>
          ))}
        </select>
        <button type="submit" className="button" disabled={mutation.isPending || !dirty}>
          {mutation.isPending ? "Saving…" : "Save status"}
        </button>
      </div>
      <p className="status-note" role="status">
        {mutation.isSuccess && !dirty ? "Saved. Your saved place is kept." : "Changing the status never removes your saved place."}
      </p>
      {mutation.isError ? (
        <p className="status-error" role="alert">
          {failureKind(mutation.error) === "network"
            ? "Could not reach the server. The status was not saved; try again."
            : failureKind(mutation.error) === "csrf"
              ? "This page is out of date. Reload it, then save again."
              : failureKind(mutation.error) === "not_found"
                ? "This book is no longer in your library."
                : "The status was not saved. Try again."}
        </p>
      ) : null}
    </form>
  );
}
