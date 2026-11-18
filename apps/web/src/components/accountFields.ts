import { ApiError } from "../api/errors";

export type FieldErrors = Record<string, string[]>;

export type FormOutcome = { tone: "success" | "error"; text: string; serial: number } | null;

const FRIENDLY: Record<string, Record<string, string>> = {
  name: { "can't be blank": "Enter a display name." },
  current_password: {
    "can't be blank": "Enter your current password.",
    "is incorrect": "That is not your current password.",
  },
  password: {
    "can't be blank": "Enter a new password.",
    "is too short (minimum is 12 characters)": "Use at least 12 characters.",
    "is too long": "Use a shorter password: at most 72 bytes, which is fewer than 72 characters when it has accents or emoji.",
    "must include at least one lowercase letter, one uppercase letter, and one number": "Include a lowercase letter (a–z), an uppercase letter (A–Z) and a number (0–9).",
    "is invalid": "This password contains a character that cannot be used.",
  },
  password_confirmation: { "doesn't match Password": "This does not match the new password." },
};

const BLANK = /^\p{White_Space}*$/u;

export function isBlank(value: string): boolean {
  return BLANK.test(value);
}

export function fieldMessage(field: string, messages: readonly string[]): string {
  return messages.map((message) => FRIENDLY[field]?.[message] ?? `${humanize(field)} ${message}.`).join(" ");
}

function humanize(field: string): string {
  const words = field.replaceAll("_", " ");
  return words.charAt(0).toUpperCase() + words.slice(1);
}

export function splitErrors(errors: FieldErrors, fields: readonly string[]): { own: FieldErrors; record: string[] } {
  const own: FieldErrors = {};
  const record: string[] = [];
  for (const [field, messages] of Object.entries(errors)) {
    if (fields.includes(field)) own[field] = messages;
    else for (const message of messages) record.push(`${humanize(field)} ${message}`);
  }
  return { own, record };
}

export function recordRefusal(record: readonly string[]): string {
  return `Shelfarr cannot save changes to this account because its stored details are not valid (${record.join("; ")}). Nothing was changed. An administrator needs to correct the account first.`;
}

export function firstInvalid(form: HTMLFormElement | null, fields: readonly string[], errors: FieldErrors): void {
  const field = fields.find((name) => errors[name]?.length);
  if (!form || !field) return;
  const control = form.elements.namedItem(field);
  if (control instanceof HTMLInputElement) control.focus();
}

function waitText(seconds: number | null): string {
  if (seconds === null) return "a moment";
  if (seconds < 90) return `${Math.max(seconds, 1)} seconds`;
  return `${Math.ceil(seconds / 60)} minutes`;
}

export function describeWriteFailure(error: unknown, uncertain: string): string {
  if (!(error instanceof ApiError)) return uncertain;
  switch (error.kind) {
    case "network":
    case "server":
      return uncertain;
    case "csrf":
      return "This page was out of date and has been refreshed. Nothing was changed; save again.";
    case "busy":
      return "The server is busy. Nothing was changed; try again in a moment.";
    case "rate_limited":
      return `Too many attempts from this device. Nothing was changed; wait ${waitText(error.retryAfterSeconds)} and try again.`;
    case "conflict":
      return "Your password or sign-in settings were changed somewhere else while this was saving. Nothing was changed; enter your current password again.";
    case "unsupported":
      return "This account's stored password is in a form this experimental server cannot check. Nothing was changed.";
    case "not_found":
      return "Account settings are not available on this server. Nothing was changed.";
    case "contract":
      return error.status !== null && error.status >= 400 ? "The server did not accept this request. Nothing was changed; reload the page and try again." : uncertain;
    default:
      return error.code === "request_too_large" ? "That is too long to save. Nothing was changed; shorten it and try again." : "The server did not accept this request. Nothing was changed; reload the page and try again.";
  }
}
