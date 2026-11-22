import { z } from "zod";

const identifier = z.string().regex(/^[1-9]\d{0,18}$/);
const timestamp = z.iso.datetime({ offset: true });

export const serverCategoryIds = ["policy", "sources", "downloads", "library", "notifications", "people", "system"] as const;
export type ServerCategoryId = (typeof serverCategoryIds)[number];

export const fieldInputs = ["toggle", "number", "text", "url", "code", "country", "secret", "choice", "order", "events", "list", "url_list", "library", "libraries"] as const;
export type FieldInput = (typeof fieldInputs)[number];

const fieldValue = z.union([z.string(), z.number(), z.boolean(), z.array(z.string()), z.null()]);

const optionSchema = z.object({ value: z.string(), label: z.string(), description: z.string().optional() });
export type FieldOption = z.infer<typeof optionSchema>;

export const settingFieldSchema = z.object({
  key: z.string().regex(/^[a-z][a-z0-9_]{0,80}$/),
  label: z.string(),
  description: z.string(),
  input: z.enum(fieldInputs),
  value: fieldValue,
  default: fieldValue.optional(),
  configured: z.boolean().optional(),
  clearable: z.boolean().optional(),
  shown: z.string().optional(),
  managed_by: z.string().optional(),
  options: z.array(optionSchema).optional(),
  min: z.number().int().optional(),
  max: z.number().int().optional(),
  placeholder: z.string().optional(),
  warning: z.string().optional(),
  visible_when: z.object({ key: z.string(), in: z.array(z.string()) }).optional(),
});
export type SettingField = z.infer<typeof settingFieldSchema>;

export const healthStatuses = ["healthy", "degraded", "down", "not_configured", "unknown"] as const;
export type CardHealthStatus = (typeof healthStatuses)[number];

export const cardHealthSchema = z.object({
  service: z.string(),
  status: z.enum(healthStatuses).nullable(),
  message: z.string().optional(),
  checked_at: timestamp.optional(),
});
export type CardHealth = z.infer<typeof cardHealthSchema>;

export const probeSchema = z.object({ id: z.string(), label: z.string(), uses: z.enum(["draft", "saved"]), changes: z.boolean(), draft_keys: z.array(z.string()).optional() });
export type Probe = z.infer<typeof probeSchema>;

export const cardExtras = ["library_inventory", "telegram_chats", "roles"] as const;
export const cardNotes = ["path_variables", "hardcover_app"] as const;

export const settingGroupSchema = z.object({
  id: z.string(),
  heading: z.string().optional(),
  title: z.string(),
  summary: z.string(),
  toggle: z.string().optional(),
  fields: z.array(settingFieldSchema),
  advanced: z.array(settingFieldSchema),
  probes: z.array(probeSchema),
  extras: z.array(z.enum(cardExtras)),
  notes: z.array(z.enum(cardNotes)),
  health: cardHealthSchema.optional(),
});
export type SettingGroup = z.infer<typeof settingGroupSchema>;

export const settingCategorySchema = z.object({ id: z.enum(serverCategoryIds), title: z.string(), summary: z.string(), groups: z.array(settingGroupSchema) });
export type SettingCategory = z.infer<typeof settingCategorySchema>;

const settingLinkSchema = z.object({ category: z.enum(serverCategoryIds), group: z.string(), key: z.string() });

export const roleRowSchema = z.object({ action: z.string(), member: z.string(), administrator: z.string(), setting: settingLinkSchema.optional() });
export type RoleRow = z.infer<typeof roleRowSchema>;

export const serverSettingsSchema = z.object({
  account: identifier,
  categories: z.array(settingCategorySchema),
  notes: z.object({
    path_variables: z.string(),
    hardcover_app: z.object({ create_url: z.string().url(), scopes: z.string(), redirect_uri: z.string(), redirect_uri_acceptable: z.boolean() }),
  }),
  roles: z.array(roleRowSchema),
});
export type ServerSettings = z.infer<typeof serverSettingsSchema>;
export type SettingNotes = ServerSettings["notes"];

export const outcomeSchema = z.object({ tone: z.enum(["success", "error"]), message: z.string() });
export type Outcome = z.infer<typeof outcomeSchema>;

export const groupSavedSchema = z.object({ account: identifier, outcome: outcomeSchema, changed: z.array(z.string()), group: settingGroupSchema });
export type GroupSaved = z.infer<typeof groupSavedSchema>;

export const groupRejectedSchema = z.object({
  account: identifier,
  error: z.literal("invalid_settings"),
  errors: z.array(z.object({ key: z.string().nullable(), message: z.string() })),
});
export type GroupRejected = z.infer<typeof groupRejectedSchema>;

export const probeAnswerSchema = z.object({ account: identifier, outcome: outcomeSchema });

export const libraryInventorySchema = z.object({
  account: identifier,
  platform: z.string(),
  configured: z.boolean(),
  libraries: z.array(z.object({ id: z.string(), name: z.string(), media_type: z.string() })).nullable(),
  inventory: z.object({
    count: z.number().int().nonnegative(),
    available: z.number().int().nonnegative(),
    missing: z.number().int().nonnegative(),
    last_synced_at: timestamp.nullable(),
    recent: z.array(z.object({ id: z.string(), title: z.string(), author: z.string().nullable(), url: z.string().nullable(), missing: z.boolean(), details: z.array(z.string()) })),
  }),
});
export type LibraryInventory = z.infer<typeof libraryInventorySchema>;

export const telegramChatSchema = z.object({ id: identifier, label: z.string(), chat_id: z.string(), state: z.enum(["authorized", "paused", "expired", "pending"]) });
export type TelegramChat = z.infer<typeof telegramChatSchema>;

export const telegramChatsSchema = z.object({ account: identifier, chats: z.array(telegramChatSchema) });
export const telegramChatActionSchema = z.object({ account: identifier, outcome: outcomeSchema, chats: z.array(telegramChatSchema) });
export type TelegramChatAction = z.infer<typeof telegramChatActionSchema>;

export const actionAnswerSchema = z.object({ account: identifier, outcome: outcomeSchema });
