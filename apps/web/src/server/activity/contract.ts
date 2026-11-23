import { z } from "zod";

const identifier = z.string().regex(/^[1-9]\d{0,18}$/);
const timestamp = z.iso.datetime({ offset: true });

export const requestOrigins = ["web", "api", "telegram", "hardcover"] as const;
export const matchChoices = ["existing", "created"] as const;

export const activityPersonSchema = z.object({ id: identifier, name: z.string(), removed: z.boolean() });
export type ActivityPerson = z.infer<typeof activityPersonSchema>;

export const activitySubjectSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("request"), id: identifier, title: z.string() }),
  activityPersonSchema.extend({ kind: z.literal("person") }),
  z.object({ kind: z.literal("book"), id: identifier, title: z.string(), in_library: z.boolean() }),
  z.object({ kind: z.literal("other"), title: z.string() }),
]);
export type ActivitySubject = z.infer<typeof activitySubjectSchema>;

export const activityDetailsSchema = z.object({
  via: z.enum(requestOrigins).optional(),
  scopes: z.array(z.string()).optional(),
  match: z.enum(matchChoices).optional(),
});
export type ActivityDetails = z.infer<typeof activityDetailsSchema>;

export const activityEntrySchema = z.object({
  id: identifier,
  at: timestamp,
  action: z.string(),
  actor: activityPersonSchema.nullable(),
  subject: activitySubjectSchema.nullable(),
  details: activityDetailsSchema,
});
export type ActivityEntry = z.infer<typeof activityEntrySchema>;

export const activityLogSchema = z.object({
  account: identifier,
  limit: z.number().int().positive(),
  more: z.boolean(),
  entries: z.array(activityEntrySchema),
  people: z.array(activityPersonSchema),
  actions: z.array(z.string()),
});
export type ActivityLog = z.infer<typeof activityLogSchema>;

function isCalendarDay(value: string): boolean {
  const parsed = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}

export const activitySearchSchema = z.object({
  user: identifier.optional().catch(undefined),
  action: z
    .string()
    .refine((value) => !/^\p{White_Space}*$/u.test(value))
    .optional()
    .catch(undefined),
  from: z
    .string()
    .regex(/^\d{4}-\d{2}-\d{2}$/)
    .refine(isCalendarDay)
    .optional()
    .catch(undefined),
});
export type ActivityFilters = z.infer<typeof activitySearchSchema>;
