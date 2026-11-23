import { Link } from "@tanstack/react-router";
import { useId } from "react";
import type { PublicationSummary } from "../../contract";
import { Said, useSay } from "../../server/extras";
import { useServices } from "../../services";
import { isMissingReader, koboFailure, useBookKobo, useSendBook } from "./queries";
import "./kobo.css";

export function sendsToKobo(publication: Pick<PublicationSummary, "book_type" | "content_kind" | "availability">): boolean {
  return publication.book_type === "ebook" && publication.content_kind === "book" && publication.availability === "available";
}

export function SendToKobo({ publication }: { publication: Pick<PublicationSummary, "id" | "title"> }) {
  const { mode } = useServices();
  const hintId = useId();
  const kobo = useBookKobo(publication.id, true);
  const send = useSendBook(publication.id);
  const { said, say } = useSay();
  if (mode !== "rails") return null;
  if (!kobo.data) {
    return kobo.isError ? (
      <span className="kobo-send">
        <span>Your Kobo readers could not be checked.</span>
        <button type="button" className="button button--subtle" onClick={() => void kobo.refetch()}>
          Try again
        </button>
      </span>
    ) : (
      <span className="muted">Checking your Kobo readers…</span>
    );
  }
  if (kobo.data.refusal) return <span data-testid="kobo-refusal">{kobo.data.refusal}.</span>;
  if (kobo.data.readers.length === 0) {
    return (
      <Link to="/account/$section" params={{ section: "devices" }} hash="kobo-readers">
        Connect a Kobo reader
      </Link>
    );
  }
  return (
    <span className="kobo-send">
      <span id={hintId} className="field-hint">
        Choose a reader, then sync it over Wi-Fi. An EPUB is sent as a Kobo edition (KEPUB) prepared from it, so reading places can be shared both ways; the library file is not changed.
      </span>
      <span className="form-actions">
        {kobo.data.readers.map((reader) => (
          <button
            key={reader.id}
            type="button"
            className="button"
            aria-describedby={hintId}
            aria-disabled={send.isPending ? true : undefined}
            aria-busy={send.isPending && send.variables === reader.id}
            onClick={() => {
              if (send.isPending) return;
              send.mutate(reader.id, {
                onSuccess: (answer) => say("success", answer.notice),
                onError: (error) => {
                  if (isMissingReader(error)) void kobo.refetch();
                  say("error", koboFailure(error, `Shelfarr could not confirm whether ${publication.title} was queued for ${reader.name}. Check the reader's page under Devices before sending again.`));
                },
              });
            }}
          >
            {send.isPending && send.variables === reader.id ? "Sending…" : `Send to ${reader.name}`}
          </button>
        ))}
      </span>
      <Said said={said} />
    </span>
  );
}
