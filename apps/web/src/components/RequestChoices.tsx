import { useId } from "react";
import type { RequestChoice } from "../api/client";
import type { BookFormat, BookRequestResult, RequestOptions } from "../contract";

export type RequestFormat = RequestChoice["format"];
export type PlannedRequest = { format: RequestFormat; accent: boolean };
export type RequestExtras = { language: string | null; notes: string };

type FormatState = Pick<BookFormat, "book_type" | "state">;

export const FALLBACK_OPTIONS: RequestOptions = { formats: ["ebook"], default_format: "ebook", default_language: "", languages: [], note_limit: 0 };

const NOUNS: Record<BookFormat["book_type"], string> = { ebook: "ebook", audiobook: "audiobook" };

export function requestLabel(format: RequestFormat): string {
  return format === "both" ? "Request ebook and audiobook" : `Request ${NOUNS[format]}`;
}

export function offered(format: FormatState, options: RequestOptions): boolean {
  return format.state === "requestable" && options.formats.includes(format.book_type);
}

export function requestPlan(formats: readonly FormatState[], options: RequestOptions): PlannedRequest[] {
  const defaultFormat = options.default_format;
  const open = formats.filter((format) => offered(format, options)).map((format) => format.book_type);
  if (open.length === 0) return [];
  if (open.length > 1 && defaultFormat === "both") return [{ format: "both", accent: true }];
  if (defaultFormat === "ebook" || defaultFormat === "audiobook") {
    return open.includes(defaultFormat) ? [{ format: defaultFormat, accent: true }] : open.map((format) => ({ format, accent: false }));
  }
  return open.map((format) => ({ format, accent: defaultFormat === "both" }));
}

export const NO_EXTRAS: RequestExtras = { language: null, notes: "" };

export function choiceFor(format: RequestFormat, extras: RequestExtras, options: RequestOptions): RequestChoice {
  const notes = extras.notes.trim();
  return {
    format,
    language: extras.language !== null && extras.language !== options.default_language && options.languages.some((language) => language.code === extras.language) ? extras.language : undefined,
    notes: notes === "" || options.note_limit === 0 ? undefined : notes,
  };
}

export function offersLanguage(options: RequestOptions): boolean {
  return options.languages.length > 1;
}

export function RequestExtrasFields({ options, extras, onChange, disabled }: { options: RequestOptions; extras: RequestExtras; onChange: (extras: RequestExtras) => void; disabled: boolean }) {
  const languageId = useId();
  const notesId = useId();
  const hintId = useId();
  const language = offersLanguage(options);
  if (!language && options.note_limit === 0) return null;
  return (
    <details className="request-extras">
      <summary>{language ? "Language and note" : "Add a note"}</summary>
      <div className="request-extras-fields">
        {language ? (
          <div className="field">
            <label htmlFor={languageId}>Language</label>
            <select id={languageId} name="language" value={extras.language ?? options.default_language} disabled={disabled} onChange={(event) => onChange({ ...extras, language: event.target.value })}>
              {options.languages.map((choice) => (
                <option key={choice.code} value={choice.code}>
                  {choice.code === options.default_language ? `${choice.name} (server default)` : choice.name}
                </option>
              ))}
            </select>
          </div>
        ) : null}
        {options.note_limit > 0 ? (
          <div className="field">
            <label htmlFor={notesId}>Note (optional)</label>
            <textarea
              id={notesId}
              name="notes"
              rows={3}
              maxLength={options.note_limit}
              value={extras.notes}
              disabled={disabled}
              aria-describedby={hintId}
              onChange={(event) => onChange({ ...extras, notes: event.target.value })}
            />
            <p id={hintId} className="field-hint">
              A specific edition or narrator, for example. Up to {options.note_limit} characters.
            </p>
          </div>
        ) : null}
      </div>
    </details>
  );
}

export function rejectedFormats(results: readonly BookRequestResult[] | undefined): BookRequestResult[] {
  return (results ?? []).filter((result) => result.outcome === "rejected");
}

export function outcomeSentence(results: readonly BookRequestResult[] | undefined, formats: readonly FormatState[]): string {
  const created = (results ?? []).filter((result) => result.outcome === "created").map((result) => NOUNS[result.book_type]);
  if (created.length > 0) {
    const names = created.join(" and ");
    return `${names.charAt(0).toUpperCase()}${names.slice(1)} requested.`;
  }
  const existing = (results ?? []).map((result) => formats.find((format) => format.book_type === result.book_type)?.state);
  return existing.length > 0 && existing.every((state) => state === "in_library") ? "Already in the library." : "Already requested.";
}

export function RejectedFormats({ results }: { results: readonly BookRequestResult[] | undefined }) {
  const rejected = rejectedFormats(results);
  if (rejected.length === 0) return null;
  return (
    <ul className="field-error request-rejections" role="alert">
      {rejected.map((result) => (
        <li key={result.book_type}>
          The {NOUNS[result.book_type]} was not requested: {result.message ?? "the server refused it."}
        </li>
      ))}
    </ul>
  );
}
