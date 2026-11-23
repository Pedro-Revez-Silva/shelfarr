import { z } from "zod";
import { outcomeSchema, settingFieldSchema } from "../contract";

const identifier = z.string().regex(/^[1-9]\d{0,18}$/);

export const setupStepIds = ["prowlarr", "qbittorrent", "folders", "audiobookshelf", "search"] as const;
export type SetupStepId = (typeof setupStepIds)[number];

const stepId = z.enum(setupStepIds);

export const setupCardSchema = z.object({
  id: z.string(),
  phase: z.enum(["connection", "libraries"]).nullable(),
  title: z.string(),
  summary: z.string().nullable(),
  submit: z.string(),
  collapsed: z.boolean(),
  fields: z.array(settingFieldSchema),
  libraries: z.array(z.object({ id: z.string(), name: z.string(), media_type: z.string() })).optional(),
});
export type SetupCard = z.infer<typeof setupCardSchema>;

export const setupStateSchema = z.object({
  account: identifier,
  step: stepId,
  steps: z.array(z.object({ id: stepId, label: z.string() })),
  previous: stepId.nullable(),
  last: z.boolean(),
  completed: z.boolean(),
  title: z.string(),
  summary: z.string(),
  warnings: z.array(z.string()),
  library_error: z.string().nullable(),
  cards: z.array(setupCardSchema),
});
export type SetupState = z.infer<typeof setupStateSchema>;

export const setupSavedSchema = z.object({
  account: identifier,
  outcome: outcomeSchema,
  alert: z.string().nullable(),
  completed: z.boolean(),
  setup: setupStateSchema.nullable(),
});
export type SetupSaved = z.infer<typeof setupSavedSchema>;

export const setupRejectedSchema = z.object({ account: identifier, error: z.literal("setup_rejected"), message: z.string() });
export type SetupRejected = z.infer<typeof setupRejectedSchema>;

export const setupMovedSchema = z.object({ account: identifier, completed: z.boolean(), setup: setupStateSchema.nullable() });
export type SetupMoved = z.infer<typeof setupMovedSchema>;
