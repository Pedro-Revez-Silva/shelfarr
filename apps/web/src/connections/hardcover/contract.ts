import { z } from "zod";

const identifier = z.string().regex(/^[1-9]\d{0,18}$/);
const timestamp = z.iso.datetime({ offset: true });
const sitePath = z.string().regex(/^\/(?![\/\\])/, "Expected a path on this server");

export const HARDCOVER_ORIGINS: readonly string[] = ["https://hardcover.app", "https://api.hardcover.app"];

export function isHardcoverPage(value: string): boolean {
  if (!URL.canParse(value)) return false;
  const url = new URL(value);
  return url.protocol === "https:" && HARDCOVER_ORIGINS.includes(url.origin) && url.username === "" && url.password === "";
}

const hardcoverPage = z.string().refine(isHardcoverPage, "Expected a page on hardcover.app");

export const hardcoverConnectionSchema = z.object({
  version: z.string().min(1),
  username: z.string(),
  profile_url: hardcoverPage.nullable(),
  method: z.enum(["sign_in", "api_key"]),
  state: z.enum(["active", "needs_reconnecting"]),
  problem: z.string().nullable(),
});
export type HardcoverConnection = z.infer<typeof hardcoverConnectionSchema>;

export const hardcoverDeviceSchema = z.object({
  user_code: z.string().min(1).max(32),
  verification_uri: hardcoverPage,
  verification_uri_complete: hardcoverPage.nullable(),
  expires_at: timestamp,
  interval: z.number().int().positive(),
});
export type HardcoverDevice = z.infer<typeof hardcoverDeviceSchema>;

export const hardcoverOutcomeSchema = z.object({ tone: z.enum(["success", "error"]), message: z.string() });
export type HardcoverOutcome = z.infer<typeof hardcoverOutcomeSchema>;

export const hardcoverStateSchema = z.object({
  enabled: z.boolean(),
  methods: z.object({ sign_in: z.boolean(), code: z.boolean(), api_key: z.boolean() }),
  connection: hardcoverConnectionSchema.nullable(),
  device: hardcoverDeviceSchema.nullable(),
  outcome: hardcoverOutcomeSchema.nullable(),
  links: z.object({ following: sitePath, api_key_page: hardcoverPage.optional() }),
});
export type HardcoverState = z.infer<typeof hardcoverStateSchema>;

export const hardcoverEnvelopeSchema = z.object({ account: identifier, hardcover: hardcoverStateSchema, notice: z.string().optional() });
export type HardcoverEnvelope = z.infer<typeof hardcoverEnvelopeSchema>;

export const hardcoverRefusalSchema = z.object({
  account: identifier,
  error: z.enum(["hardcover_unavailable", "hardcover_changed", "hardcover_refused", "invalid_api_key"]),
  message: z.string(),
  hardcover: hardcoverStateSchema,
});
export type HardcoverRefusal = z.infer<typeof hardcoverRefusalSchema>;

export const hardcoverAuthorizationSchema = z.object({ account: identifier, authorization_url: hardcoverPage });
export type HardcoverAuthorization = z.infer<typeof hardcoverAuthorizationSchema>;

export const hardcoverDevicePollSchema = z.object({
  account: identifier,
  status: z.enum(["pending", "approved", "failed"]),
  message: z.string().optional(),
  hardcover: hardcoverStateSchema,
});
export type HardcoverDevicePoll = z.infer<typeof hardcoverDevicePollSchema>;
