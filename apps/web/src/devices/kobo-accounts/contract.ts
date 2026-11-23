import { z } from "zod";
import { koboTones } from "../kobo/contract";

const identifier = z.string().regex(/^[1-9]\d{0,18}$/);
const timestamp = z.iso.datetime({ offset: true });
const sitePath = z.string().regex(/^\/(?!\/)/, "Expected a path on this server");

export const KOBO_ACTIVATION_PAGE = "https://www.kobo.com/activate";

export const koboAccountStates = ["pending", "connected", "reauthorization_required", "incomplete"] as const;

export const koboAccountRowSchema = z.object({
  id: identifier,
  name: z.string(),
  state: z.enum(koboAccountStates),
  status_label: z.string(),
  shared_with: z.number().int().nonnegative(),
});
export type KoboAccountRow = z.infer<typeof koboAccountRowSchema>;

export const receivedCatalogueSchema = z.object({ id: identifier, name: z.string(), owner_name: z.string(), sendable_count: z.number().int().nonnegative() });
export type ReceivedCatalogue = z.infer<typeof receivedCatalogueSchema>;

export const koboAccountsSchema = z.object({
  account: identifier,
  kobo_accounts: z.array(koboAccountRowSchema),
  received: z.array(receivedCatalogueSchema),
  new_account: z.object({ name: z.string() }),
});
export type KoboAccounts = z.infer<typeof koboAccountsSchema>;

const sharePersonSchema = z.object({ id: identifier, name: z.string(), username: z.string(), shared_at: timestamp, inactive: z.boolean() });
export type SharePerson = z.infer<typeof sharePersonSchema>;

export const koboAccountSchema = koboAccountRowSchema.extend({
  version: z.string().min(1),
  error: z.string().nullable(),
  activation: z.object({ code: z.string().regex(/^\d{6,12}$/), page: z.literal(KOBO_ACTIVATION_PAGE), expires_at: timestamp }).nullable(),
  kobo_email: z.string().nullable(),
  refreshing: z.boolean(),
  can_refresh: z.boolean(),
  last_synced_at: timestamp.nullable(),
  sharing: z.object({ people: z.array(sharePersonSchema), candidates: z.array(z.object({ id: identifier, label: z.string() })) }).nullable(),
});
export type KoboAccount = z.infer<typeof koboAccountSchema>;

export const koboAccountEnvelopeSchema = z.object({ account: identifier, kobo_account: koboAccountSchema, notice: z.string().optional() });
export type KoboAccountEnvelope = z.infer<typeof koboAccountEnvelopeSchema>;

export const koboAccountRefusalSchema = z.object({
  account: identifier,
  error: z.enum(["refresh_refused", "share_refused", "kobo_account_changed"]),
  message: z.string(),
  kobo_account: koboAccountSchema,
});
export type KoboAccountRefusal = z.infer<typeof koboAccountRefusalSchema>;

export const koboAccountDisconnectedSchema = z.object({ account: identifier, disconnected: identifier, notice: z.string() });
export type KoboAccountDisconnected = z.infer<typeof koboAccountDisconnectedSchema>;

const eligibilitySchema = z.object({ tone: z.enum(koboTones), label: z.string() });

export const catalogueFilters = ["all", "sendable"] as const;

export const koboCatalogueSchema = z.object({
  account: identifier,
  catalogue: z.object({
    kobo_account: z.object({ id: identifier, name: z.string(), owner: z.boolean(), owner_name: z.string(), connected: z.boolean(), last_synced_at: timestamp.nullable() }),
    filter: z.enum(catalogueFilters),
    page: z.number().int().positive(),
    more: z.boolean(),
    count: z.number().int().nonnegative(),
    sendable_count: z.number().int().nonnegative(),
    books: z.array(z.object({ id: identifier, title: z.string(), author: z.string().nullable(), eligibility: eligibilitySchema })),
  }),
});
export type KoboCatalogue = z.infer<typeof koboCatalogueSchema>["catalogue"];

export const koboBookSchema = z.object({
  id: identifier,
  title: z.string(),
  author: z.string().nullable(),
  from: z.string(),
  kobo_account: z.object({ id: identifier, name: z.string(), owner: z.boolean(), owner_name: z.string() }),
  cover: sitePath.nullable(),
  eligibility: eligibilitySchema.extend({ detail: z.string() }),
  deliverable: z.boolean(),
  offered: z.string().nullable(),
  copy: z
    .object({
      version: z.string().min(1).nullable(),
      preparing: z.boolean(),
      failure: z.string().nullable(),
      ready: z.object({ summary: z.string(), prepared_at: timestamp, stale: z.boolean() }).nullable(),
      unavailable: z.string().nullable(),
      explanation: z.string().nullable(),
    })
    .nullable(),
  readers: z.array(z.object({ id: identifier, name: z.string(), status: z.string(), older_copy: z.boolean(), sent: z.boolean() })),
});
export type KoboBook = z.infer<typeof koboBookSchema>;

export const koboBookEnvelopeSchema = z.object({ account: identifier, book: koboBookSchema, notice: z.string().optional() });
export type KoboBookEnvelope = z.infer<typeof koboBookEnvelopeSchema>;

export const koboBookRefusalSchema = z.object({ account: identifier, error: z.enum(["prepare_refused", "deliver_refused", "copy_changed"]), message: z.string(), book: koboBookSchema });
export type KoboBookRefusal = z.infer<typeof koboBookRefusalSchema>;

export const catalogueSearchSchema = z.object({
  filter: z.literal("sendable").optional().catch(undefined),
  page: z
    .string()
    .regex(/^[1-9]\d{0,5}$/)
    .optional()
    .catch(undefined),
});
export type CatalogueSearch = z.infer<typeof catalogueSearchSchema>;
