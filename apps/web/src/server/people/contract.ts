import { z } from "zod";

const identifier = z.string().regex(/^[1-9]\d{0,18}$/);
const timestamp = z.iso.datetime({ offset: true });

export const personRoles = ["member", "administrator"] as const;
export type PersonRole = (typeof personRoles)[number];

export const personRowSchema = z.object({
  id: identifier,
  name: z.string(),
  username: z.string(),
  role: z.enum(personRoles),
  self: z.boolean(),
  created_at: timestamp,
});
export type PersonRow = z.infer<typeof personRowSchema>;

export const peopleSchema = z.object({ account: identifier, users: z.array(personRowSchema) });
export type People = z.infer<typeof peopleSchema>;

export const personRecordSchema = personRowSchema.extend({ requests: z.number().int().nonnegative(), version: z.string().min(1) });
export type PersonRecord = z.infer<typeof personRecordSchema>;

export const personEnvelopeSchema = z.object({ account: identifier, user: personRecordSchema, administrators: z.number().int().nonnegative() });
export type PersonEnvelope = z.infer<typeof personEnvelopeSchema>;

export const personRejectedSchema = z.object({ account: identifier, error: z.literal("invalid_user"), errors: z.record(z.string(), z.array(z.string())) });
export type PersonRejected = z.infer<typeof personRejectedSchema>;

export const ownAccountSchema = z.object({ account: identifier, error: z.literal("own_account"), message: z.string() });
export type OwnAccount = z.infer<typeof ownAccountSchema>;

export const personChangedSchema = personEnvelopeSchema.extend({ error: z.literal("user_changed") });
export type PersonChanged = z.infer<typeof personChangedSchema>;

export const personRemovedSchema = z.object({ account: identifier, removed: identifier });
export type PersonRemoved = z.infer<typeof personRemovedSchema>;
