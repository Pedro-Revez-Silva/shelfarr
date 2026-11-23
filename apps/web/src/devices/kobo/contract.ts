import { z } from "zod";

const identifier = z.string().regex(/^[1-9]\d{0,18}$/);
const timestamp = z.iso.datetime({ offset: true });
const sitePath = z.string().regex(/^\/(?!\/)/, "Expected a path on this server");

export const koboTones = ["ok", "warning", "choice", "info"] as const;
export type KoboTone = (typeof koboTones)[number];

export const koboNoticeSchema = z.object({ tone: z.enum(koboTones), text: z.string(), choosable: z.boolean() });
export type KoboNotice = z.infer<typeof koboNoticeSchema>;

export const koboSettingsSchema = z.object({ store_coexistence: z.boolean(), share_progress: z.boolean(), receive_progress: z.boolean() });
export type KoboSettings = z.infer<typeof koboSettingsSchema>;

export const koboReaderRowSchema = koboSettingsSchema.extend({
  id: identifier,
  name: z.string(),
  mode: z.enum(["store_and_shelfarr", "shelfarr_only"]),
  mode_label: z.string(),
  base_url: z.string(),
  last_sync_at: timestamp.nullable(),
  version: z.string().min(1),
});
export type KoboReaderRow = z.infer<typeof koboReaderRowSchema>;

export const koboDeliverySchema = z.object({
  entitlement_id: z.string().min(1),
  choice: z.string().min(1),
  title: z.string(),
  source: z.enum(["library", "kobo_account"]),
  link: z.discriminatedUnion("kind", [z.object({ kind: z.literal("library"), publication_id: identifier }), z.object({ kind: z.literal("kobo_book"), href: sitePath })]).nullable(),
  status: z.string(),
  edition: z.string().nullable(),
  place: koboNoticeSchema.nullable(),
  outbound: koboNoticeSchema.nullable(),
  send_again: z.object({ book_id: identifier, confirmation: z.string().nullable() }).nullable(),
});
export type KoboDelivery = z.infer<typeof koboDeliverySchema>;

export const koboReaderSchema = koboReaderRowSchema.extend({
  store_status: koboNoticeSchema.nullable(),
  placeholder_sign_in: z.string().nullable(),
  store_endpoint: z.string(),
  deliveries: z.array(koboDeliverySchema),
});
export type KoboReader = z.infer<typeof koboReaderSchema>;

export const newKoboReaderSchema = koboSettingsSchema.extend({ base_url: z.string() });
export type NewKoboReaderDefaults = z.infer<typeof newKoboReaderSchema>;

export const koboReadersSchema = z.object({ account: identifier, readers: z.array(koboReaderRowSchema), new_reader: newKoboReaderSchema });
export type KoboReaders = z.infer<typeof koboReadersSchema>;

export const koboReaderEnvelopeSchema = z.object({ account: identifier, reader: koboReaderSchema, notice: z.string().optional() });
export type KoboReaderEnvelope = z.infer<typeof koboReaderEnvelopeSchema>;

export const koboSetupSchema = z.object({ account: identifier, reader: koboReaderRowSchema, setup: z.object({ endpoint: z.string().min(1), store_endpoint: z.string() }) });
export type KoboSetup = z.infer<typeof koboSetupSchema>;

export const koboRejectedSchema = z.object({ account: identifier, error: z.literal("invalid_reader"), errors: z.record(z.string(), z.array(z.string())), messages: z.array(z.string()) });
export type KoboRejected = z.infer<typeof koboRejectedSchema>;

export const koboChangedSchema = z.object({ account: identifier, error: z.literal("reader_changed"), reader: koboReaderSchema });
export type KoboChanged = z.infer<typeof koboChangedSchema>;

export const koboPlaceRefusedSchema = z.object({ account: identifier, error: z.literal("place_refused"), message: z.string(), reader: koboReaderSchema });
export type KoboPlaceRefused = z.infer<typeof koboPlaceRefusedSchema>;

export const koboRevokedSchema = z.object({ account: identifier, revoked: identifier, notice: z.string() });
export type KoboRevoked = z.infer<typeof koboRevokedSchema>;

export const koboSentSchema = z.object({ account: identifier, reader: z.object({ id: identifier, name: z.string() }), notice: z.string() });
export type KoboSent = z.infer<typeof koboSentSchema>;

export const bookKoboSchema = z.object({ account: identifier, kobo: z.object({ readers: z.array(z.object({ id: identifier, name: z.string() })), refusal: z.string().nullable() }) });
export type BookKobo = z.infer<typeof bookKoboSchema>["kobo"];
