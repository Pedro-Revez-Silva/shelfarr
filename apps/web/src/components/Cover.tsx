import { useState } from "react";
import type { PublicationSummary } from "../contract";

type Props = { publication: Pick<PublicationSummary, "title" | "author" | "book_type" | "cover">; large?: boolean };

export function Cover({ publication, large = false }: Props) {
  const url = publication.cover.url;
  return <CoverFace key={url ?? "generated"} publication={publication} url={url} large={large} />;
}

function CoverFace({ publication, url, large }: Props & { url: string | null }) {
  const [broken, setBroken] = useState(false);
  const showImage = url !== null && !broken;
  return (
    <div className={`cover-slot${large ? " cover-slot--large" : ""}`} aria-hidden="true">
      <div className={`cover cover--${publication.cover.style} cover--${publication.book_type}`} data-fallback={showImage ? undefined : "true"}>
        {showImage ? (
          <img src={url} alt="" loading="lazy" decoding="async" referrerPolicy="no-referrer" onError={() => setBroken(true)} />
        ) : (
          <>
            <span className="cover-title">{publication.title}</span>
            {publication.author ? <span className="cover-author">{publication.author}</span> : null}
          </>
        )}
      </div>
    </div>
  );
}
