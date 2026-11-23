import type { PublicationDetail, PublicationSummary } from "../contract";

const TEXT_ONLY = ["epub"] as const;
const LABEL_FORMATS: Record<string, readonly string[]> = { Ebook: ["epub"], PDF: ["pdf"], Comic: ["cbz", "epub", "pdf"] };

function readerPath(mount: string, id: string): string {
  return `${mount}/library/${id}/read`;
}

export function goReaderLink(publication: PublicationDetail, mount: string, formats: readonly string[] = TEXT_ONLY): string | null {
  if (publication.availability !== "available") return null;
  const readable = publication.action === "listen" ? publication.files.length > 0 : publication.files.some((file) => formats.includes(file.format));
  return readable ? readerPath(mount, publication.id) : null;
}

export function goSummaryReaderLink(summary: PublicationSummary, mount: string, formats: readonly string[] = TEXT_ONLY): string | null {
  if (summary.availability !== "available") return null;
  if (summary.action === "listen") return readerPath(mount, summary.id);
  const needed = LABEL_FORMATS[summary.format_label] ?? [];
  return needed.length > 0 && needed.every((format) => formats.includes(format)) ? readerPath(mount, summary.id) : null;
}

type ReaderTarget = { mode: "rails" | "go"; boot: { mount: string; reader_formats?: readonly string[] | undefined } };

export function publicationReaderHref(publication: PublicationDetail, { mode, boot }: ReaderTarget): string | null {
  if (mode === "go") return goReaderLink(publication, boot.mount, boot.reader_formats);
  if (!boot.reader_formats) return publication.reader_url;
  return goReaderLink(publication, boot.mount, boot.reader_formats) ?? publication.reader_url;
}

export function summaryReaderHref(summary: PublicationSummary, { mode, boot }: ReaderTarget): string | null {
  if (mode === "go") return goSummaryReaderLink(summary, boot.mount, boot.reader_formats);
  if (!boot.reader_formats) return summary.reader_url;
  return goSummaryReaderLink(summary, boot.mount, boot.reader_formats) ?? summary.reader_url;
}
