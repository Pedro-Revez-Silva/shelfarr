import type { PublicationDetail, PublicationSummary } from "../contract";

const TEXT_ONLY = ["epub"] as const;
const LABEL_FORMATS: Record<string, readonly string[]> = { Ebook: ["epub"], PDF: ["pdf"], Comic: ["cbz", "epub", "pdf"] };
const READER_PATHS = { go: /^\/library\/([1-9]\d{0,18})\/read$/, rails: /^\/read\/([1-9]\d{0,18})$/ } as const;

export type ReaderMode = keyof typeof READER_PATHS;

export function readerPath(mode: ReaderMode, mount: string, id: string): string {
  return mode === "rails" ? `${mount}/read/${id}` : `${mount}/library/${id}/read`;
}

export function readerPublicationId(pathname: string, mount: string, mode: ReaderMode): string | null {
  if (!pathname.startsWith(`${mount}/`)) return null;
  return READER_PATHS[mode].exec(pathname.slice(mount.length))?.[1] ?? null;
}

function readable(publication: PublicationDetail, formats: readonly string[]): boolean {
  if (publication.availability !== "available") return false;
  return publication.action === "listen" ? publication.files.length > 0 : publication.files.some((file) => formats.includes(file.format));
}

function summaryReadable(summary: PublicationSummary, formats: readonly string[]): boolean {
  if (summary.availability !== "available") return false;
  if (summary.action === "listen") return true;
  const needed = LABEL_FORMATS[summary.format_label] ?? [];
  return needed.length > 0 && needed.every((format) => formats.includes(format));
}

export function goReaderLink(publication: PublicationDetail, mount: string, formats: readonly string[] = TEXT_ONLY): string | null {
  return readable(publication, formats) ? readerPath("go", mount, publication.id) : null;
}

export function goSummaryReaderLink(summary: PublicationSummary, mount: string, formats: readonly string[] = TEXT_ONLY): string | null {
  return summaryReadable(summary, formats) ? readerPath("go", mount, summary.id) : null;
}

type ReaderTarget = { mode: ReaderMode; boot: { mount: string; reader_formats?: readonly string[] | undefined } };

export function publicationReaderHref(publication: PublicationDetail, { mode, boot }: ReaderTarget): string | null {
  if (mode === "go") return goReaderLink(publication, boot.mount, boot.reader_formats);
  if (!boot.reader_formats) return publication.reader_url;
  return readable(publication, boot.reader_formats) ? readerPath("rails", boot.mount, publication.id) : publication.reader_url;
}

export function summaryReaderHref(summary: PublicationSummary, { mode, boot }: ReaderTarget): string | null {
  if (mode === "go") return goSummaryReaderLink(summary, boot.mount, boot.reader_formats);
  if (!boot.reader_formats) return summary.reader_url;
  return summaryReadable(summary, boot.reader_formats) ? readerPath("rails", boot.mount, summary.id) : summary.reader_url;
}
