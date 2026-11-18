import type { PublicationDetail, PublicationSummary } from "../contract";

function readerPath(mount: string, id: string): string {
  return `${mount}/library/${id}/read`;
}

export function goReaderLink(publication: PublicationDetail, mount: string): string | null {
  if (publication.availability !== "available") return null;
  const readable = publication.action === "listen" ? publication.files.length > 0 : publication.files.some((file) => file.format === "epub");
  return readable ? readerPath(mount, publication.id) : null;
}

export function goSummaryReaderLink(summary: PublicationSummary, mount: string): string | null {
  if (summary.availability !== "available") return null;
  return summary.action === "listen" || summary.format_label === "Ebook" ? readerPath(mount, summary.id) : null;
}
