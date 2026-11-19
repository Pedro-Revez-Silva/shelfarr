import type { DownloadStatus, RequestStatus, RequestSummary } from "../contract";

export const STATUS_LABELS: Record<RequestStatus, string> = {
  pending: "Pending",
  searching: "Searching",
  not_found: "Not found",
  downloading: "Downloading",
  processing: "Processing",
  completed: "Completed",
  failed: "Failed",
  awaiting_purchase: "Awaiting purchase",
  unknown: "Unknown status",
};

export const BOOK_TYPE_LABELS: Record<RequestSummary["book_type"], string> = {
  ebook: "Ebook",
  audiobook: "Audiobook",
  comicbook: "Comics & Manga",
  unknown: "Unknown format",
};

export const DOWNLOAD_LABELS: Record<DownloadStatus, string> = {
  queued: "Queued",
  downloading: "Downloading",
  paused: "Paused",
  completed: "Completed",
  failed: "Failed",
  unknown: "Unknown",
};

export function coverOf(request: RequestSummary) {
  return { title: request.title, author: request.author, book_type: request.book_type === "audiobook" ? ("audiobook" as const) : ("ebook" as const), cover: request.cover };
}

const UNITS: [Intl.RelativeTimeFormatUnit, number][] = [
  ["year", 365 * 24 * 3600],
  ["month", 30 * 24 * 3600],
  ["day", 24 * 3600],
  ["hour", 3600],
  ["minute", 60],
];

export function relativeTime(iso: string, now = Date.now()): string {
  const seconds = Math.round((Date.parse(iso) - now) / 1000);
  const format = new Intl.RelativeTimeFormat("en", { numeric: "auto" });
  for (const [unit, size] of UNITS) {
    if (Math.abs(seconds) >= size) return format.format(Math.trunc(seconds / size), unit);
  }
  return seconds > 0 ? "in less than a minute" : "less than a minute ago";
}

const absolute = new Intl.DateTimeFormat("en", { dateStyle: "long", timeStyle: "short" });

export function absoluteTime(iso: string): string {
  return absolute.format(new Date(iso));
}

export function Time({ iso, relative = false }: { iso: string; relative?: boolean }) {
  return (
    <time dateTime={iso} title={relative ? absoluteTime(iso) : undefined}>
      {relative ? relativeTime(iso) : absoluteTime(iso)}
    </time>
  );
}

export function StatusBadges({ request }: { request: RequestSummary }) {
  return (
    <ul className="request-badges" aria-label="Request state">
      <li className="badge">{BOOK_TYPE_LABELS[request.book_type]}</li>
      <li className={`badge badge--status badge--${request.status}`}>{STATUS_LABELS[request.status]}</li>
      {request.attention_needed ? (
        <li className="badge badge--attention">
          <span aria-hidden="true">⚠</span>Attention
        </li>
      ) : null}
    </ul>
  );
}
