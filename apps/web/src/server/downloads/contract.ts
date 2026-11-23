import { z } from "zod";
import { healthStatuses, outcomeSchema } from "../contract";

const identifier = z.string().regex(/^[1-9]\d{0,18}$/);
const timestamp = z.iso.datetime({ offset: true });
const kind = z.enum(["torrent", "usenet"]);

export const downloadClientSchema = z.object({
  id: identifier,
  version: z.string().min(1),
  name: z.string(),
  client_type: z.string(),
  kind,
  url: z.string(),
  url_hidden: z.boolean(),
  username: z.string(),
  category: z.string(),
  download_path: z.string(),
  enabled: z.boolean(),
  priority: z.number().int(),
  torrent_verification_max_attempts: z.number(),
  torrent_verification_wait_time: z.number(),
  password_saved: z.boolean(),
  api_key_saved: z.boolean(),
  rule_count: z.number().int().nonnegative(),
  rule_ids: z.array(identifier),
});
export type DownloadClient = z.infer<typeof downloadClientSchema>;

export const routingRuleSchema = z.object({
  id: identifier,
  version: z.string().min(1),
  provider: z.string(),
  provider_label: z.string(),
  indexer_name: z.string(),
  download_type: kind,
  client_id: identifier,
  client_name: z.string(),
  client_enabled: z.boolean(),
  client_kind: kind,
  enabled: z.boolean(),
});
export type RoutingRule = z.infer<typeof routingRuleSchema>;

export const clientTypeSchema = z.object({ value: z.string(), label: z.string(), kind, authentication: z.boolean(), api_key: z.boolean(), verification: z.boolean() });
export type ClientType = z.infer<typeof clientTypeSchema>;

const choiceSchema = z.object({ value: z.string(), label: z.string() });

const downloadsFields = {
  account: identifier,
  clients: z.array(downloadClientSchema),
  rules: z.array(routingRuleSchema),
  client_types: z.array(clientTypeSchema).min(1),
  providers: z.array(choiceSchema).min(1),
  download_types: z.array(z.object({ value: kind, label: z.string() })).min(1),
  defaults: z.object({ client_type: z.string(), enabled: z.boolean(), torrent_verification_max_attempts: z.number().int(), torrent_verification_wait_time: z.number().int() }),
  health: z.object({ status: z.enum(healthStatuses).nullable(), message: z.string().nullable(), checked_at: timestamp.nullable() }),
};

export const downloadsSchema = z.object(downloadsFields);
export type Downloads = z.infer<typeof downloadsSchema>;

export const downloadsActionSchema = z.object({ ...downloadsFields, outcome: outcomeSchema, created: identifier.optional(), tested: identifier.optional(), moved: z.boolean().optional() });
export type DownloadsAction = z.infer<typeof downloadsActionSchema>;

export const downloadsChangedSchema = z.object({ ...downloadsFields, error: z.literal("download_changed") });

export const downloadsRejectedSchema = z.object({
  account: identifier,
  error: z.literal("invalid_record"),
  errors: z.array(z.object({ field: z.string(), message: z.string() })),
});
export type DownloadsRejection = z.infer<typeof downloadsRejectedSchema>["errors"];
