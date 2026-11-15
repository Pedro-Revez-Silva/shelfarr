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

export const errorEnvelopeSchema = z.object({ error: z.string(), message: z.string().optional() });

export const bootSchema = z.object({
  version: z.literal(CONTRACT_VERSION),
  account: identifier,
  mount: z.string(),
  api: z.string().startsWith("/"),
  classic_library: sitePath,
});
export type Boot = z.infer<typeof bootSchema>;

export const libraryFiltersSchema = z.object({
  q: z.string().max(200).optional().catch(undefined),
  type: z.enum(publicationTypes).optional().catch(undefined),
  status: readingStatusSchema.optional().catch(undefined),
  sort: z.enum(librarySorts).optional().catch(undefined),
});
export type LibraryFilters = z.infer<typeof libraryFiltersSchema>;
