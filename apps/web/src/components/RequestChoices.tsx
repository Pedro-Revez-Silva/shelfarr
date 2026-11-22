import { useId } from "react";
import type { RequestChoice } from "../api/client";
import type { BookFormat, BookRequestResult, RequestOptions } from "../contract";

export type RequestFormat = RequestChoice["format"];
export type PlannedRequest = { format: RequestFormat; accent: boolean };
export type RequestExtras = { language: string; notes: string };

type FormatState = Pick<BookFormat, "book_type" | "state">;

export const FALLBACK_OPTIONS: RequestOptions = { default_format: "ebook", default_language: "", languages: [], note_limit: 0 };

const NOUNS: Record<BookFormat["book_type"], string> = { ebook: "ebook", audiobook: "audiobook" };

export function requestLabel(format: RequestFormat): string {
  return format === "both" ? "Request ebook and audiobook" : `Request ${NOUNS[format]}`;
}

export function requestPlan(formats: readonly FormatState[], defaultFormat: RequestOptions["default_format"]): PlannedRequest[] {
  const open = formats.filter((format) => format.state === "requestable").map((format) => format.book_type);
  if (open.length === 0) return [];
  if (open.length > 1 && defaultFormat === "both") return [{ format: "both", accent: true }];
  if (defaultFormat === "ebook" || defaultFormat === "audiobook") {
    return open.includes(defaultFormat) ? [{ format: defaultFormat, accent: true }] : open.map((format) => ({ format, accent: false }));
  }
  return open.map((format) => ({ format, accent: defaultFormat === "both" }));
}

export function initialExtras(options: RequestOptions): RequestExtras {
  return { language: options.default_language, notes: "" };
}

export function choiceFor(format: RequestFormat, extras: RequestExtras, options: RequestOptions): RequestChoice {
  const notes = extras.notes.trim();
  return {
    format,
    language: extras.language !== options.default_language && options.languages.some((language) => language.code === extras.language) ? extras.language : undefined,
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
            <select id={languageId} name="language" value={extras.language} disabled={disabled} onChange={(event) => onChange({ ...extras, language: event.target.value })}>
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

export function createdSentence(results: readonly BookRequestResult[] | undefined): string {
  const created = (results ?? []).filter((result) => result.outcome === "created").map((result) => NOUNS[result.book_type]);
  if (created.length === 0) return "Already requested.";
  const names = created.join(" and ");
  return `${names.charAt(0).toUpperCase()}${names.slice(1)} requested.`;
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
