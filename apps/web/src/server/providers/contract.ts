import { z } from "zod";
import { outcomeSchema } from "../contract";

const identifier = z.string().regex(/^[1-9]\d{0,18}$/);

export const acquisitionProviderSchema = z.object({
  id: identifier,
  version: z.string().min(1),
  name: z.string(),
  url: z.string(),
  url_hidden: z.boolean(),
  api_key_saved: z.boolean(),
  enabled: z.boolean(),
  allow_private_network: z.boolean(),
  supports_ebooks: z.boolean(),
  supports_audiobooks: z.boolean(),
  supports_comicbooks: z.boolean(),
  timeout_seconds: z.number().int(),
  priority: z.number().int().nonnegative(),
});
export type AcquisitionProvider = z.infer<typeof acquisitionProviderSchema>;

const providersFields = {
  account: identifier,
  providers: z.array(acquisitionProviderSchema),
  defaults: z.object({
    enabled: z.boolean(),
    allow_private_network: z.boolean(),
    supports_ebooks: z.boolean(),
    supports_audiobooks: z.boolean(),
    supports_comicbooks: z.boolean(),
    timeout_seconds: z.number().int(),
  }),
};

export const providersSchema = z.object(providersFields);
export type Providers = z.infer<typeof providersSchema>;

export const providersActionSchema = z.object({ ...providersFields, outcome: outcomeSchema, created: identifier.optional(), tested: identifier.optional() });
export type ProvidersAction = z.infer<typeof providersActionSchema>;

export const providersChangedSchema = z.object({ ...providersFields, error: z.literal("provider_changed") });

export const providersRejectedSchema = z.object({
  account: identifier,
  error: z.literal("invalid_record"),
  errors: z.array(z.object({ field: z.string(), message: z.string() })),
});
export type ProvidersRejection = z.infer<typeof providersRejectedSchema>["errors"];
