import { z } from "zod";

z.config({ jitless: true });

export const CONTRACT_VERSION = 1;

const identifier = z.string().regex(/^[1-9]\d{0,18}$/);
const timestamp = z.iso.datetime({ offset: true });

const httpsUrl = z.string().refine((value) => {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.username === "" && url.password === "";
  } catch {
    return false;
  }
}, "Expected a plain https address");

const sitePath = z.string().regex(/^\/(?!\/)/, "Expected a path on this server");

export const coverStyles = ["clay", "moss", "slate", "oat", "plum", "stone"] as const;
export const readingStatuses = ["unread", "in_progress", "finished"] as const;
export const publicationTypes = ["ebook", "audiobook"] as const;
export const librarySorts = ["recent", "title"] as const;

export const readingStatusSchema = z.enum(readingStatuses);
export type ReadingStatus = z.infer<typeof readingStatusSchema>;

export const progressSchema = z.object({
  asset_id: z.string().min(1).max(128),
  position_seconds: z.number().nonnegative().nullable(),
  fraction: z.number().min(0).max(1).nullable(),
  page: z.number().int().positive().nullable(),
  version: z.number().int().nonnegative(),
  observed_at: timestamp.nullable(),
  updated_at: timestamp,
});
export type Progress = z.infer<typeof progressSchema>;

export const publicationSummarySchema = z.object({
  id: identifier,
  title: z.string(),
  author: z.string().nullable(),
  book_type: z.enum(publicationTypes),
  content_kind: z.enum(["book", "graphic"]),
  format_label: z.string(),
  availability: z.enum(["available", "unavailable"]),
  action: z.enum(["read", "listen"]),
  cover: z.object({ url: httpsUrl.nullable(), style: z.enum(coverStyles) }),
  reading_status: readingStatusSchema,
  progress: progressSchema.nullable(),
  progress_label: z.string(),
  reader_url: sitePath,
});
export type PublicationSummary = z.infer<typeof publicationSummarySchema>;

export const publicationFileSchema = z.object({
  id: z.string().min(1).max(128),
  filename: z.string(),
  format: z.string(),
  media_type: z.string(),
  size_bytes: z.number().int().nonnegative(),
  position: z.number().int().nonnegative(),
  page_count: z.number().int().nonnegative().nullable(),
});
export type PublicationFile = z.infer<typeof publicationFileSchema>;

export const publicationDetailSchema = publicationSummarySchema.extend({
  description: z.string(),
  files: z.array(publicationFileSchema),
});
export type PublicationDetail = z.infer<typeof publicationDetailSchema>;

export const librarySchema = z.object({
  account: identifier,
  items: z.array(publicationSummarySchema),
  next_cursor: z.string().min(1).nullable(),
});
export type LibraryPage = z.infer<typeof librarySchema>;

export const continueSchema = z.object({
  account: identifier,
  items: z.array(publicationSummarySchema),
});
export type ContinueShelf = z.infer<typeof continueSchema>;

export const publicationEnvelopeSchema = z.object({
  account: identifier,
  publication: publicationDetailSchema,
});
export type PublicationEnvelope = z.infer<typeof publicationEnvelopeSchema>;

export const sessionSchema = z.object({
  account: z.object({ id: identifier, name: z.string() }),
  server: z.object({ name: z.string(), version: z.string() }),
  links: z.object({
    legacy_library: sitePath,
    discover: sitePath,
    requests: sitePath,
    account: sitePath,
  }),
  admin: z.object({ url: sitePath }).optional(),
});
export type Session = z.infer<typeof sessionSchema>;

export const profileSchema = z.object({ id: identifier, username: z.string(), name: z.string() });
export type Profile = z.infer<typeof profileSchema>;

export const accountEnvelopeSchema = z.object({ account: identifier, profile: profileSchema }).refine((envelope) => envelope.profile.id === envelope.account, "The profile belongs to another account");
export type AccountEnvelope = z.infer<typeof accountEnvelopeSchema>;

export const accountRejectionSchema = z.object({
  account: identifier,
  error: z.enum(["invalid_profile", "invalid_password"]),
  errors: z.record(z.string(), z.array(z.string())),
});
export type AccountRejection = z.infer<typeof accountRejectionSchema>;

export type PasswordChange = { current_password: string; password: string; password_confirmation: string };

export const errorEnvelopeSchema = z.object({ error: z.string(), message: z.string().optional() });

export const bootSchema = z.object({
  version: z.literal(CONTRACT_VERSION),
  account: identifier,
  mount: z.string(),
  api: z.string().startsWith("/"),
  classic_library: sitePath,
});

export const goViews = ["library", "details", "connect", "reader", "account", "discover", "requests", "request"] as const;
export type GoView = (typeof goViews)[number];

export const pageEngineSchema = z.object({
  engine: sitePath,
  worker: sitePath,
  files: z.record(z.enum(["cMapUrl", "standardFontDataUrl", "wasmUrl"]), z.record(z.string().regex(/^[A-Za-z0-9][A-Za-z0-9-]*\.(?:bcmap|pfb|ttf|wasm)$/), sitePath)),
});
export type PageEngine = z.infer<typeof pageEngineSchema>;

export const goBootSchema = z.object({
  version: z.literal(CONTRACT_VERSION),
  runtime: z.literal("go"),
  view: z.enum(goViews),
  mount: sitePath,
  api: sitePath,
  reader_engine: sitePath.optional(),
  reader_formats: z.array(z.string()).optional(),
  page_engine: pageEngineSchema.optional(),
});
export type GoBoot = z.infer<typeof goBootSchema>;

export type Boot = {
  version: typeof CONTRACT_VERSION;
  account: string;
  mount: string;
  api: string;
  classic_library: string | null;
  runtime?: "go";
  reader_formats?: readonly string[];
};

export const bootstrapSchema = z.discriminatedUnion("authenticated", [
  z.object({ authenticated: z.literal(true), account: identifier, csrf_token: z.string().min(1), expires_in: z.number().int().nonnegative() }),
  z.object({
    authenticated: z.literal(false),
    csrf_token: z.string().min(1),
    expires_in: z.number().int().nonnegative(),
    sign_in: z.object({ available: z.boolean(), reason: z.string().nullable() }),
  }),
]);
export type Bootstrap = z.infer<typeof bootstrapSchema>;

export const connectGrantSchema = z.object({
  pending: z.boolean(),
  decidable: z.boolean(),
  client_name: z.string().optional(),
  upgrade: z.boolean().optional(),
  requesting: z.boolean().optional(),
  scopes: z.array(z.string()).optional(),
  expires_at: timestamp.optional(),
});
export type ConnectGrant = z.infer<typeof connectGrantSchema>;

export const connectInspectSchema = z.object({
  account: identifier,
  account_name: z.string(),
  grant: connectGrantSchema.nullable(),
});
export type ConnectInspect = z.infer<typeof connectInspectSchema>;

export const connectDecisionSchema = z.object({
  account: identifier,
  decision: z.enum(["allowed", "denied"]),
  upgrade: z.boolean(),
  requesting: z.boolean(),
});
export type ConnectDecision = z.infer<typeof connectDecisionSchema>;

export const discoverStates = ["available", "server_off", "provider_disabled", "provider_not_selected", "provider_paused"] as const;
export type DiscoverState = (typeof discoverStates)[number];
export const libraryCopyTypes = ["ebook", "audiobook", "comicbook"] as const;
export type LibraryCopyType = (typeof libraryCopyTypes)[number];

const openLibraryWork = z.string().regex(/^OL[1-9]\d{0,11}W$/);
const openLibraryCover = z.string().regex(/^https:\/\/covers\.openlibrary\.org\/b\/id\/[1-9]\d{0,15}-M\.jpg$/);

export const discoverItemSchema = z
  .object({
    id: openLibraryWork,
    title: z.string().min(1),
    author: z.string().min(1).nullable(),
    first_publish_year: z.number().int().min(1).max(9999).nullable(),
    edition_count: z.number().int().nonnegative().nullable(),
    cover_url: openLibraryCover.nullable(),
    source_url: z.string(),
    library: z.array(z.object({ book_type: z.enum(libraryCopyTypes), publication_id: identifier })),
  })
  .refine((item) => item.source_url === `https://openlibrary.org/works/${item.id}`, "The work link must point at the same Open Library work");
export type DiscoverItem = z.infer<typeof discoverItemSchema>;

export const discoverSchema = z.object({
  account: identifier,
  provider: z.object({ name: z.literal("Open Library"), url: z.literal("https://openlibrary.org") }),
  search: z.enum(discoverStates),
  retry_after: z.number().int().nonnegative().optional(),
  query: z.string().nullable(),
  items: z.array(discoverItemSchema),
});
export type DiscoverAnswer = z.infer<typeof discoverSchema>;

export const discoverSearchSchema = z.object({
  q: z.string().optional().catch(undefined),
});
export type DiscoverSearch = z.infer<typeof discoverSearchSchema>;

export const libraryFiltersSchema = z.object({
  q: z.string().max(200).optional().catch(undefined),
  type: z.enum(publicationTypes).optional().catch(undefined),
  status: readingStatusSchema.optional().catch(undefined),
  sort: z.enum(librarySorts).optional().catch(undefined),
});
export type LibraryFilters = z.infer<typeof libraryFiltersSchema>;

export const requestStatuses = ["pending", "searching", "not_found", "downloading", "processing", "completed", "failed", "awaiting_purchase", "unknown"] as const;
export type RequestStatus = (typeof requestStatuses)[number];
export const requestFilterStatuses = ["active", "pending", "searching", "not_found", "downloading", "processing", "completed", "failed", "awaiting_purchase"] as const;
export type RequestFilterStatus = (typeof requestFilterStatuses)[number];
export const requestBookTypes = ["ebook", "audiobook", "comicbook", "unknown"] as const;
export const downloadStatuses = ["queued", "downloading", "paused", "completed", "failed", "unknown"] as const;
export type DownloadStatus = (typeof downloadStatuses)[number];

const percent = z.number().int().min(0).max(100);

export const requestLibrarySchema = z.discriminatedUnion("state", [z.object({ state: z.literal("available"), publication_id: identifier }), z.object({ state: z.literal("unavailable") })]);

export const requestSummarySchema = z.object({
  id: identifier,
  status: z.enum(requestStatuses),
  attention_needed: z.boolean(),
  title: z.string(),
  author: z.string().nullable(),
  book_type: z.enum(requestBookTypes),
  cover: z.object({ url: httpsUrl.nullable(), style: z.enum(coverStyles) }),
  download_percent: percent.nullable(),
  created_at: timestamp,
  updated_at: timestamp,
  completed_at: timestamp.nullable(),
  next_retry_at: timestamp.nullable(),
  library: requestLibrarySchema.nullable(),
  requested_by: z.object({ name: z.string(), self: z.boolean() }).optional(),
});
export type RequestSummary = z.infer<typeof requestSummarySchema>;

export const requestDetailSchema = requestSummarySchema.extend({
  attention_reason: z.string().nullable(),
  downloads: z.array(z.object({ status: z.enum(downloadStatuses), progress: percent.nullable() })),
});
export type RequestDetail = z.infer<typeof requestDetailSchema>;

export const requestListSchema = z
  .object({
    account: identifier,
    scope: z.enum(["own", "all"]),
    filter: z.object({ status: z.enum(requestFilterStatuses).nullable(), attention: z.boolean(), q: z.string().nullable() }),
    counts: z.object({ attention: z.number().int().nonnegative(), active: z.number().int().nonnegative() }),
    page: z.number().int().positive(),
    per_page: z.number().int().positive(),
    total: z.number().int().nonnegative(),
    total_pages: z.number().int().positive(),
    items: z.array(requestSummarySchema),
  })
  .refine((list) => list.scope === "all" || list.items.every((item) => item.requested_by === undefined), "A member's list must not name requesters");
export type RequestList = z.infer<typeof requestListSchema>;

export const requestEnvelopeSchema = z.object({ account: identifier, request: requestDetailSchema });

export const MAX_REQUEST_QUERY = 200;

export const requestFiltersSchema = z.object({
  status: z.enum(requestFilterStatuses).optional().catch(undefined),
  attention: z.literal("true").optional().catch(undefined),
  q: z.string().optional().catch(undefined),
  page: z.string().regex(/^\d{1,7}$/).optional().catch(undefined),
});
export type RequestFilters = z.infer<typeof requestFiltersSchema>;

const assetIdentifier = z.string().min(1).max(128);

export const locatorSchema = z.looseObject({
  href: z.string(),
  type: z.string().optional(),
  locations: z
    .looseObject({
      progression: z.number().nullable().optional(),
      totalProgression: z.number().nullable().optional(),
      position: z.number().nullable().optional(),
      cfi: z.unknown().optional(),
      fragments: z.unknown().optional(),
    })
    .nullable()
    .optional(),
});
export type Locator = z.infer<typeof locatorSchema>;

export const storedProgressSchema = z.object({
  asset_id: assetIdentifier,
  locator: locatorSchema.nullable(),
  position_seconds: z.number().nonnegative().nullable(),
  version: z.number().int().positive(),
  observed_at: timestamp.nullable(),
  updated_at: timestamp,
  client_mutation_id: z.string(),
});
export type StoredProgress = z.infer<typeof storedProgressSchema>;

export const readerAssetSchema = z.object({
  id: assetIdentifier,
  filename: z.string(),
  format: z.string(),
  media_type: z.string(),
  size_bytes: z.number().int().nonnegative(),
  position: z.number().int().nonnegative(),
  url: sitePath,
  page_count: z.number().int().positive().optional(),
  reading_order_url: sitePath.optional(),
});
export type ReaderAsset = z.infer<typeof readerAssetSchema>;

export const readerPublicationSchema = z.object({
  id: identifier,
  title: z.string(),
  author: z.string().nullable(),
  book_type: z.enum(publicationTypes),
  content_kind: z.enum(["book", "graphic"]),
  reading_status: readingStatusSchema,
  assets: z.array(readerAssetSchema),
  other_formats: z.array(z.string()),
  progress: storedProgressSchema.nullable(),
});
export type ReaderPublication = z.infer<typeof readerPublicationSchema>;

export const readerEnvelopeSchema = z.object({ account: identifier, publication: readerPublicationSchema });

export const progressEnvelopeSchema = z.object({ account: identifier, progress: storedProgressSchema.nullable() });

export const progressConflictSchema = z.object({ account: identifier, error: z.literal("progress_conflict"), progress: storedProgressSchema.nullable() });

export type ProgressPlace = { asset_id: string; locator: Locator; position_seconds?: never } | { asset_id: string; position_seconds: number; locator?: never };

export type ProgressRequest = ProgressPlace & {
  observed_at: string;
  expected_version: number;
  client_mutation_id: string;
  resolve_conflict?: true;
};
