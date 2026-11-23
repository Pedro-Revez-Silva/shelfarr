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

export const workSources = ["hardcover", "google_books", "openlibrary", "comic_vine"] as const;
const workSourceId = z.string().regex(/^[A-Za-z0-9_-]{1,64}$/);
const workIdentifier = z.string().regex(/^(?:hardcover|google_books|openlibrary|comic_vine):[A-Za-z0-9_-]{1,64}$/);

export const bookAddressSchema = z.object({ source: z.enum(workSources), id: workSourceId });
export type BookAddress = z.infer<typeof bookAddressSchema>;

export const publicationDetailSchema = publicationSummarySchema.extend({
  description: z.string(),
  files: z.array(publicationFileSchema),
  book_page: bookAddressSchema.nullable().optional(),
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
  notifications: z.object({ url: sitePath, unread: z.number().int().nonnegative() }).optional(),
  capabilities: z
    .object({ administrator: z.boolean(), can_upload: z.boolean(), single_sign_on: z.boolean(), hardcover_personal_access: z.boolean() })
    .optional(),
});
export type Session = z.infer<typeof sessionSchema>;

export const apiTokenSchema = z.object({
  id: identifier,
  name: z.string(),
  prefix: z.string(),
  scopes: z.array(z.string()),
  app: z.boolean(),
  state: z.enum(["active", "revoked", "expired"]),
  created_at: timestamp,
  last_used_at: timestamp.nullable(),
  expires_at: timestamp.nullable(),
});
export type ApiToken = z.infer<typeof apiTokenSchema>;

export const accountSettingsSchema = z.object({
  admin: z.boolean(),
  member_since: timestamp,
  requests: z.object({ total: z.number().int().nonnegative(), completed: z.number().int().nonnegative(), pending: z.number().int().nonnegative() }),
  two_factor: z.object({ enabled: z.boolean() }),
  oidc: z.object({ configured: z.boolean(), provider: z.string().nullable(), linked: z.boolean(), link_page: sitePath.nullable(), password_required: z.boolean() }),
  api_tokens: z.array(apiTokenSchema),
  token_scopes: z.array(z.object({ scope: z.string(), label: z.string() })),
  links: z.object({
    kobo_readers: sitePath,
    kobo_accounts: sitePath,
    hardcover: sitePath,
    sign_out: sitePath,
    phone_app: sitePath,
    reading_library: sitePath,
    kobo_shared: sitePath.optional(),
    android_app: sitePath.optional(),
    admin: sitePath.optional(),
  }),
  server: z.object({ release: z.string(), beta: z.boolean(), series: z.string() }),
});
export type AccountSettings = z.infer<typeof accountSettingsSchema>;

export const profileSchema = z.object({ id: identifier, username: z.string(), name: z.string(), settings: accountSettingsSchema.optional() });
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

export const offlineBootSchema = z.object({ worker: sitePath, scope: sitePath, downloads: sitePath, continuity_cookie: z.string().regex(/^[A-Za-z0-9_]{1,64}$/).optional() });
export type OfflineBoot = z.infer<typeof offlineBootSchema>;

export const bootSchema = z.object({
  version: z.literal(CONTRACT_VERSION),
  account: identifier,
  mount: z.string(),
  api: z.string().startsWith("/"),
  classic_library: sitePath,
  reader_formats: z.array(z.string()).optional(),
  offline: offlineBootSchema.optional(),
});

export const goViews = ["library", "details", "connect", "reader", "account", "discover", "requests", "request", "admin", "server_settings", "downloads"] as const;
export type GoView = (typeof goViews)[number];

export const pageEngineSchema = z.object({
  engine: sitePath,
  worker: sitePath,
  files: z.record(z.enum(["cMapUrl", "standardFontDataUrl", "wasmUrl"]), z.record(z.string().regex(/^[A-Za-z0-9][A-Za-z0-9-]*\.(?:bcmap|pfb|ttf|wasm)$/), sitePath)),
});
export type PageEngine = z.infer<typeof pageEngineSchema>;

export const goBootSchema = z.object({
  version: z.literal(CONTRACT_VERSION),
  runtime: z.enum(["go", "rails"]),
  view: z.enum(goViews),
  mount: sitePath,
  api: sitePath,
  reader_engine: sitePath.optional(),
  reader_formats: z.array(z.string()).optional(),
  page_engine: pageEngineSchema.optional(),
  offline: offlineBootSchema.optional(),
  classic_downloads: sitePath.optional(),
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
  offline?: OfflineBoot;
  classic_downloads?: string;
};

export const bootstrapSchema = z.discriminatedUnion("authenticated", [
  z.object({ authenticated: z.literal(true), account: identifier, csrf_token: z.string().min(1), expires_in: z.number().int().nonnegative(), offline_expires_in: z.number().int().nonnegative().optional(), offline_continuity: z.string().min(1).optional() }),
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
  requesting: z.boolean().optional(),
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

export const bookCopySchema = z.object({
  id: identifier,
  title: z.string(),
  format: z.string().nullable(),
  size_bytes: z.number().int().nonnegative().nullable(),
  language: z.string().nullable(),
  source: z.string(),
  state: z.enum(["pending", "selected", "rejected"]),
  skipped: z.boolean(),
  downloadable: z.boolean(),
});
export type BookCopy = z.infer<typeof bookCopySchema>;

export const requestActionsSchema = z.object({
  cancel: z.boolean(),
  remove: z.enum(["admin_remove", "delete_history"]).nullable(),
  retry: z.boolean(),
  search_again: z.boolean(),
  manual_download: z.boolean(),
  replaces_library_file: z.boolean(),
  upload_url: sitePath.nullable(),
  download_url: sitePath.nullable(),
});
export type RequestActions = z.infer<typeof requestActionsSchema>;

export const storeOfferSchema = z.object({
  id: identifier,
  title: z.string(),
  author: z.string().nullable(),
  provider: z.string(),
  drm: z.string(),
  price: z.string().nullable(),
  formats: z.array(z.string()),
  language: z.string().nullable(),
  quoted_at: timestamp.nullable(),
  url: httpsUrl,
});
export type StoreOffer = z.infer<typeof storeOfferSchema>;

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
  book_page: bookAddressSchema.nullable().optional(),
});
export type RequestSummary = z.infer<typeof requestSummarySchema>;

export const requestDetailSchema = requestSummarySchema.extend({
  attention_reason: z.string().nullable(),
  downloads: z.array(z.object({ status: z.enum(downloadStatuses), progress: percent.nullable() })),
  acquisition: z.boolean().optional(),
  choice_needed: z.boolean().optional(),
  notes: z.string().nullable().optional(),
  collection_title: z.string().nullable().optional(),
  retry_count: z.number().int().nonnegative().optional(),
  actions: requestActionsSchema.optional(),
  store_offers: z.array(storeOfferSchema).optional(),
  copies: z.object({ selectable: z.boolean(), candidates: z.array(bookCopySchema) }).optional(),
  events: z.array(z.object({ title: z.string(), message: z.string().nullable(), level: z.string(), at: timestamp })).optional(),
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
  page: z.string().max(64).optional().catch(undefined),
});
export type RequestFilters = z.infer<typeof requestFiltersSchema>;

const assetIdentifier = z.string().min(1).max(128);

export const locatorSchema = z.looseObject({
  href: z.string(),
  type: z.string().nullable().optional(),
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
  classic_reader: z.object({ url: sitePath, read_along: z.boolean() }).optional(),
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

export const requestCreationSchema = z.discriminatedUnion("outcome", [
  z.object({ account: identifier, outcome: z.literal("created"), request: z.object({ id: identifier }), warnings: z.array(z.string()) }),
  z.object({ account: identifier, outcome: z.literal("existing"), request: z.object({ id: identifier }) }),
  z.object({ account: identifier, outcome: z.literal("already_requested") }),
  z.object({ account: identifier, outcome: z.literal("already_in_library"), library: z.object({ publication_id: identifier }).nullable() }),
]);
export type RequestCreation = z.infer<typeof requestCreationSchema>;

export const selectionStates = ["queued", "downloading", "failed", "completed"] as const;
export const selectionSchema = z.object({ state: z.enum(selectionStates), result_id: identifier, code: z.string().nullable() });
export type Selection = z.infer<typeof selectionSchema>;
export const selectionEnvelopeSchema = z.object({ account: identifier, selection: selectionSchema });

export const acquisitionSchema = z.object({
  account: identifier,
  request: z.object({ id: identifier, status: z.enum(requestStatuses) }),
  candidates: z.array(z.object({ id: identifier, title: z.string() })),
  selection: selectionSchema.nullable(),
  search: z.object({ state: z.enum(["retry_scheduled", "refused", "waiting"]), code: z.string(), retry_at: timestamp }).nullable(),
});
export type Acquisition = z.infer<typeof acquisitionSchema>;

export const healthServices = ["indexer", "download_client", "download_paths", "output_paths", "audiobookshelf", "hardcover"] as const;
export type HealthService = (typeof healthServices)[number];
export const healthStatuses = ["healthy", "degraded", "down", "not_configured", "unknown"] as const;
export type HealthStatus = (typeof healthStatuses)[number];

const tally = z.number().int().nonnegative();

export const serviceHealthSchema = z.object({
  service: z.enum(healthServices),
  status: z.enum(healthStatuses).nullable(),
  checked_at: timestamp.nullable(),
  label: z.string().optional(),
  message: z.string().optional(),
  fix: z.object({ category: z.string(), group: z.string(), label: z.string() }).optional(),
});
export type ServiceHealth = z.infer<typeof serviceHealthSchema>;

export const serverOverviewSchema = z
  .object({
    account: identifier,
    counts: z.object({ users: tally, books: tally, active_requests: tally, attention_requests: tally }),
    services: z.array(serviceHealthSchema),
    release: z
      .object({
        build: z.string(),
        channel: z.string(),
        beta: z.boolean(),
        series: z.string(),
        image: z.string(),
        image_tag: z.string(),
        guide_url: z.string().url(),
        latest: z.object({
          state: z.enum(["unchecked", "available", "current", "failed"]),
          version: z.string().optional(),
          release_url: z.string().nullable().optional(),
          message: z.string().optional(),
        }),
      })
      .optional(),
    pending: z.array(z.object({ label: z.string(), url: sitePath })).optional(),
  })
  .refine((overview) => overview.services.length === healthServices.length && overview.services.every((entry, index) => entry.service === healthServices[index]), "Every health service must be listed once, in order");
export type ServerOverview = z.infer<typeof serverOverviewSchema>;

export const metadataReachStates = [...discoverStates, "settings_unreadable"] as const;
export type MetadataReach = (typeof metadataReachStates)[number];

const savedLimit = z.number().int().min(-Number.MAX_SAFE_INTEGER).max(Number.MAX_SAFE_INTEGER);

const metadataSettingsShape = {
  account: identifier,
  revision: z.string().regex(/^[0-9a-f]{32}$/),
  open_library: z.object({ enabled: z.boolean().nullable(), search_limit: savedLimit.nullable() }),
  defaults: z.object({ enabled: z.boolean(), search_limit: z.number().int().positive() }),
  search_limit_range: z.object({ min: z.number().int().positive(), max: z.number().int().positive() }),
  discover: z.object({
    search: z.enum(metadataReachStates),
    result_limit: z.number().int().nonnegative().nullable(),
    max_results: z.number().int().positive(),
    retry_after: z.number().int().optional(),
  }),
};

export const metadataSettingsSchema = z.object(metadataSettingsShape);
export type MetadataSettings = z.infer<typeof metadataSettingsSchema>;

export const metadataConflictSchema = z.object({ ...metadataSettingsShape, error: z.literal("settings_conflict") });

export const metadataRejectionSchema = z.object({
  account: identifier,
  error: z.literal("invalid_settings"),
  errors: z.partialRecord(z.enum(["enabled", "search_limit"]), z.array(z.string())),
});
export type MetadataRejection = z.infer<typeof metadataRejectionSchema>;

export type MetadataChange = { enabled?: boolean; search_limit?: number };

export const bookFormatTypes = ["ebook", "audiobook"] as const;
export const bookFormatStates = ["requestable", "requested", "requested_by_someone", "in_library"] as const;
export const bookRequestStages = ["queued", "searching", "not_found", "awaiting_purchase", "downloading", "processing", "available", "completed", "failed"] as const;


export const bookRequestSchema = z.object({
  id: identifier,
  status: z.string(),
  stage: z.enum(bookRequestStages),
  attention_needed: z.boolean(),
  download_percent: percent.nullable(),
  can_cancel: z.boolean(),
  next_retry_at: timestamp.nullable(),
  created_at: timestamp,
  updated_at: timestamp,
  own: z.boolean(),
  choice_needed: z.boolean(),
  requested_by: z.string().optional(),
  issue: z.string().nullable().optional(),
  copies: z.object({ selectable: z.boolean(), can_search_again: z.boolean(), candidates: z.array(bookCopySchema) }).optional(),
});
export type BookRequest = z.infer<typeof bookRequestSchema>;

export const bookFormatSchema = z.object({
  book_type: z.enum(bookFormatTypes),
  state: z.enum(bookFormatStates),
  publication: publicationSummarySchema.nullable(),
  request: bookRequestSchema.nullable(),
});
export type BookFormat = z.infer<typeof bookFormatSchema>;

export const requestFormatChoices = ["ask", "ebook", "audiobook", "both"] as const;
export const requestOptionsSchema = z.object({
  formats: z.array(z.enum(bookFormatTypes)),
  default_format: z.enum(requestFormatChoices),
  default_language: z.string(),
  languages: z.array(z.object({ code: z.string().min(1), name: z.string().min(1) })),
  note_limit: z.number().int().positive(),
});
export type RequestOptions = z.infer<typeof requestOptionsSchema>;

export const bookSchema = z.object({
  id: workIdentifier,
  also: z.array(workIdentifier),
  details: z.enum(["library", "catalogue", "missing"]),
  title: z.string().nullable(),
  author: z.string().nullable(),
  year: z.number().int().nullable(),
  description: z.string().nullable(),
  cover: z.object({ url: httpsUrl.nullable(), style: z.enum(coverStyles) }),
  source: z.object({ name: z.string(), url: httpsUrl.nullable() }),
  formats: z.array(bookFormatSchema),
  request_options: requestOptionsSchema.optional(),
});
export type Book = z.infer<typeof bookSchema>;

export const bookEnvelopeSchema = z.object({ account: identifier, book: bookSchema });
export const bookRequestResultSchema = z.object({ book_type: z.enum(bookFormatTypes), outcome: z.enum(["created", "existing", "rejected"]), message: z.string().optional() });
export type BookRequestResult = z.infer<typeof bookRequestResultSchema>;
export const bookRequestOutcomeSchema = z.object({ account: identifier, outcome: z.enum(["created", "existing"]), results: z.array(bookRequestResultSchema).optional(), book: bookSchema });
export type BookRequestOutcome = z.infer<typeof bookRequestOutcomeSchema>;
export const requestActionSchema = z.object({ account: identifier, request: z.object({ id: identifier, status: z.string() }), message: z.string().optional() });
export type RequestActionAnswer = z.infer<typeof requestActionSchema>;

export const twoFactorSetupSchema = z.object({ account: identifier, setup: z.object({ secret: z.string().min(1), uri: z.string().startsWith("otpauth://"), qr_svg: z.string().nullable() }) });
export type TwoFactorSetup = z.infer<typeof twoFactorSetupSchema>["setup"];
export const backupCodesSchema = z.object({ account: identifier, backup_codes: z.array(z.string().min(1)).min(1) });
export const createdTokenSchema = z.object({ account: identifier, token: apiTokenSchema, secret: z.string().min(1) });
export type CreatedToken = z.infer<typeof createdTokenSchema>;

export const catalogueItemSchema = z.object({
  book: bookAddressSchema.extend({ metadata: z.string().regex(/^[A-Za-z0-9_-]{32}$/).nullable().optional() }),
  title: z.string(),
  author: z.string().nullable(),
  year: z.number().int().nullable(),
  cover: z.object({ url: httpsUrl.nullable(), style: z.enum(coverStyles) }),
  source_name: z.string(),
  formats: z.array(z.object({ book_type: z.enum(bookFormatTypes), state: z.enum(bookFormatStates) })),
});
export type CatalogueItem = z.infer<typeof catalogueItemSchema>;

export const catalogueSchema = z.object({
  account: identifier,
  query: z.string(),
  providers: z.array(z.string()),
  unavailable: z.array(z.string()),
  items: z.array(catalogueItemSchema),
  request_options: requestOptionsSchema.optional(),
});
export type CatalogueAnswer = z.infer<typeof catalogueSchema>;

export const bookSearchSchema = z.object({
  metadata: z.string().max(64).optional().catch(undefined),
  q: z.string().max(200).optional().catch(undefined),
});
export type BookSearch = z.infer<typeof bookSearchSchema>;
