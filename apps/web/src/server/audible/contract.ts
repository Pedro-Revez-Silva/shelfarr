import { z } from "zod";
import { outcomeSchema } from "../contract";

const identifier = z.string().regex(/^[1-9]\d{0,18}$/);
const timestamp = z.iso.datetime({ offset: true });
const count = z.object({ status: z.string(), count: z.number().int().positive() });
const amazonLink = z
  .string()
  .refine((value) => {
    try {
      const url = new URL(value);
      return url.protocol === "https:" && url.username === "" && url.password === "";
    } catch {
      return false;
    }
  })
  .nullable();

export const SYNC_STATES = ["never_synced", "queued", "syncing", "failed", "succeeded"] as const;
export const ITEM_STATES = ["not_eligible", "in_shelfarr", "on_server", "possible_match", "waiting", "stalled", "queued", "starting", "downloading", "processing", "failed", "in_libation", "not_backed_up"] as const;

const audibleFields = {
  account: identifier,
  connection: z.object({
    saved: z.boolean(),
    url: z.string(),
    default_url: z.string(),
    bridge_token_saved: z.boolean(),
    token_file_managed: z.boolean(),
    enabled: z.boolean(),
    allow_private_network: z.boolean(),
    timeout_seconds: z.number().int(),
    companion_version: z.string().nullable(),
    provider_version: z.string().nullable(),
    status: z.enum(["needs_setup", "ready", "busy", "unavailable"]),
    problem: z.string().nullable(),
    locked: z.boolean(),
  }),
  sign_in: z.object({
    state: z.enum(["not_ready", "starting", "pending", "connected", "needs_sign_in"]),
    accounts: z.array(z.object({ label: z.string(), marketplace: z.string(), authenticated: z.boolean() })),
    accounts_paused: z.boolean(),
    locked: z.boolean(),
    reregister_default: z.boolean(),
    login_url: amazonLink.optional(),
    sign_in_token: z.string().regex(/^[0-9a-f]{64}$/).optional(),
    expires_at: timestamp.nullable().optional(),
  }),
  sync: z.object({
    state: z.enum(SYNC_STATES),
    recoverable: z.boolean(),
    job_recorded: z.boolean(),
    refreshing: z.boolean(),
    started_at: timestamp.nullable(),
    last_synced_at: timestamp.nullable(),
    error: z.string().nullable(),
    action: z.string(),
    available: z.boolean(),
  }),
  library: z.object({ total: z.number().int().nonnegative(), purchased: z.number().int().nonnegative(), subscription: z.number().int().nonnegative() }),
  active_backups: z.object({ total: z.number().int().nonnegative(), counts: z.array(count) }),
  existing_backup: z.object({
    available: z.boolean(),
    prompt: z.boolean(),
    total: z.number().int().nonnegative(),
    remaining: z.number().int().nonnegative(),
    processed: z.number().int().nonnegative(),
    counts: z.array(count),
  }),
  automation: z.object({
    scheduled_sync_enabled: z.boolean(),
    interval_minutes: z.number().int(),
    intervals: z.array(z.object({ minutes: z.number().int().positive(), label: z.string() })),
    next_sync_at: timestamp.nullable(),
    automatic_backup_enabled: z.boolean(),
    owner: z.string().nullable(),
    owner_ready: z.boolean(),
    baseline_ready: z.boolean(),
    first_sync_done: z.boolean(),
  }),
  marketplaces: z.array(z.object({ value: z.string(), label: z.string() })),
  working: z.boolean(),
  revision: z.string().regex(/^(?:unsaved|[0-9a-f]{16})$/),
  catalogue_generation: z.string().regex(/^(?:unsaved|[0-9a-f]{16})$/),
};

export const audibleSchema = z.object(audibleFields);
export type Audible = z.infer<typeof audibleSchema>;

export const audibleActionSchema = z.object({ ...audibleFields, outcome: outcomeSchema, tested: z.boolean().optional(), item: identifier.optional() });
export type AudibleAction = z.infer<typeof audibleActionSchema>;

export const audibleRejectedSchema = z.object({
  account: identifier,
  error: z.literal("invalid_record"),
  errors: z.array(z.object({ field: z.string(), message: z.string() })),
});
export type AudibleRejection = z.infer<typeof audibleRejectedSchema>["errors"];

export const catalogueItemSchema = z.object({
  id: identifier,
  title: z.string(),
  author: z.string(),
  ownership: z.enum(["purchased", "subscription", "unknown"]),
  book_id: identifier.nullable(),
  origin: z.enum(["existing", "automatic", "manual"]).nullable(),
  state: z.enum(ITEM_STATES),
  detail: z.string().nullable(),
  action: z.object({ label: z.string(), separate_edition: z.boolean(), available: z.boolean() }).nullable(),
});
export type CatalogueItem = z.infer<typeof catalogueItemSchema>;

export const catalogueSchema = z.object({
  account: identifier,
  query: z.string(),
  page: z.number().int().positive(),
  pages: z.number().int().positive(),
  total: z.number().int().nonnegative(),
  synced: z.boolean(),
  generation: z.string().regex(/^(?:unsaved|[0-9a-f]{16})$/),
  items: z.array(catalogueItemSchema),
});
export type Catalogue = z.infer<typeof catalogueSchema>;

export const revisionSchema = z.object({ account: identifier, revision: z.string().regex(/^(?:unsaved|[0-9a-f]{16})$/) });

export const audibleSearchSchema = z.object({
  audible_q: z.string().max(200).optional().catch(undefined),
  audible_page: z.string().regex(/^[1-9]\d{0,8}$/).optional().catch(undefined),
});
export type AudibleSearch = z.infer<typeof audibleSearchSchema>;
