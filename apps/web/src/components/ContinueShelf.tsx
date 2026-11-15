import { Link } from "@tanstack/react-router";
import type { PublicationSummary } from "../contract";
import { Cover } from "./Cover";

export function ContinueShelf({ items }: { items: PublicationSummary[] }) {
  if (items.length === 0) return null;
  return (
    <section className="continue" aria-labelledby="continue-heading">
      <h2 id="continue-heading">Keep going</h2>
      <ul className="continue-list">
        {items.map((item) => (
          <li key={item.id}>
            <article className="resume-card">
              <Cover publication={item} />
              <div className="resume-copy">
                <p className="book-format">{item.action === "listen" ? "Listening" : "Reading"}</p>
                <h3>
                  <Link to="/library/$publicationId" params={{ publicationId: item.id }} className="card-link">
                    {item.title}
                  </Link>
                </h3>
                {item.author ? <p className="book-author">{item.author}</p> : null}
                <footer>
                  <a className="resume-link" href={item.reader_url}>
                    {item.progress_label}
                    <span className="sr-only">
                      {" "}
                      — open {item.title} in the {item.action === "listen" ? "player" : "reader"}
                    </span>
                  </a>
                </footer>
              </div>
            </article>
          </li>
        ))}
      </ul>
    </section>
  );
}
