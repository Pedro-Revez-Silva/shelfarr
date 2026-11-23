import { z } from "zod";

const identifier = z.string().regex(/^[1-9]\d{0,18}$/);
const timestamp = z.iso.datetime({ offset: true });

export const uploadStatuses = ["pending", "processing", "completed", "failed"] as const;
export type UploadStatus = (typeof uploadStatuses)[number];
export const uploadBookTypes = ["ebook", "audiobook", "comicbook"] as const;
export type UploadBookType = (typeof uploadBookTypes)[number];

export const uploadSchema = z.object({
  id: identifier,
  filename: z.string(),
  size: z.number().int().nonnegative().nullable(),
  book_type: z.enum(uploadBookTypes).nullable(),
  status: z.enum(uploadStatuses),
  created_at: timestamp,
  processed_at: timestamp.nullable(),
  parsed: z.object({ title: z.string(), author: z.string().nullable(), confidence: z.number().int().nullable() }).nullable(),
  book: z.object({ title: z.string(), author: z.string().nullable(), acquired: z.boolean(), publication_id: identifier.nullable() }).nullable(),
  request_id: identifier.nullable(),
  uploaded_by_you: z.boolean(),
  failure: z.string().nullable(),
  uploaded_by: z.string().optional(),
  manual_match: z.boolean().optional(),
  reserved_file: z.boolean().optional(),
  actions: z.object({ retry: z.boolean(), match: z.boolean(), remove: z.boolean() }).optional(),
});
export type Upload = z.infer<typeof uploadSchema>;

export const uploadsSchema = z.object({
  account: identifier,
  can_upload: z.boolean(),
  formats: z.object({ audiobook: z.array(z.string()), ebook: z.array(z.string()), comicbook: z.array(z.string()) }),
  max_bytes: z.number().int().positive(),
  page: z.number().int().positive(),
  per_page: z.number().int().positive(),
  total: z.number().int().nonnegative(),
  total_pages: z.number().int().positive(),
  items: z.array(uploadSchema),
});
export type Uploads = z.infer<typeof uploadsSchema>;
export type UploadFormats = Uploads["formats"];

export const uploadRequestSchema = z.object({
  account: identifier,
  request: z.object({ id: identifier, title: z.string(), author: z.string().nullable(), book_type: z.enum(uploadBookTypes).nullable(), open: z.boolean(), message: z.string().nullable() }),
});
export type UploadRequest = z.infer<typeof uploadRequestSchema>["request"];

export const uploadCreatedSchema = z.object({
  account: identifier,
  notice: z.string().optional(),
  alert: z.string().optional(),
  uploads: z.array(identifier),
  request_id: identifier.optional(),
});
export type UploadCreated = z.infer<typeof uploadCreatedSchema>;

export const uploadOutcomeSchema = z.object({ account: identifier, outcome: z.object({ tone: z.enum(["success", "error"]), message: z.string() }) });
export type UploadOutcome = z.infer<typeof uploadOutcomeSchema>["outcome"];

export const uploadMatchesSchema = z.object({
  account: identifier,
  book_type: z.enum(uploadBookTypes),
  query: z.string(),
  page: z.number().int().positive(),
  more: z.boolean(),
  books: z.array(z.object({ id: identifier, title: z.string(), author: z.string().nullable() })),
  manual_book: z.object({ title: z.string(), author: z.string() }),
});
export type UploadMatches = z.infer<typeof uploadMatchesSchema>;

export const uploadsSearchSchema = z.object({
  request: identifier.optional().catch(undefined),
  page: z.string().regex(/^[1-9]\d{0,5}$/).optional().catch(undefined),
});
export type UploadsSearch = z.infer<typeof uploadsSearchSchema>;
