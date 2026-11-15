import { Link } from "@tanstack/react-router";
import type { PublicationSummary } from "../contract";
import { Cover } from "./Cover";

export function PublicationCard({ publication }: { publication: PublicationSummary }) {
  const unavailable = publication.availability === "unavailable";
  return (
    <article className="book-card">
      <Cover publication={publication} />
      <p className="book-format">{publication.format_label}</p>
      <h3>
        <Link to="/library/$publicationId" params={{ publicationId: publication.id }} className="card-link">
          {publication.title}
        </Link>
      </h3>
      {publication.author ? <p className="book-author">{publication.author}</p> : null}
      <p className={`book-state${unavailable ? " book-state--warning" : ""}`}>{publication.progress_label}</p>
      {publication.progress?.fraction != null && publication.reading_status === "in_progress" ? (
        <progress className="book-progress" max={1} value={publication.progress.fraction} aria-label={`Progress for ${publication.title}`} />
      ) : null}
    </article>
  );
}
