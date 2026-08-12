/**
 * Zod schemas for webhook-sources e automation-rules (feature Webhooks, Task 12).
 * TRIGGER_EVENTS deve espelhar exatamente os 5 eventos que o motor
 * (`lib/automation/engine.ts` → EXPECTED_ENTITY_KIND) reconhece.
 */
import { z } from "zod";

export const TRIGGER_EVENTS = [
  "lead.created",
  "lead.stage_changed",
  "message.received",
  "lead.tag_added",
  "contact.tag_added",
] as const;

export const conditionSchema = z.object({
  field: z.string().min(1).max(200),
  op: z.enum(["eq", "neq", "contains"]),
  value: z.string().max(500),
});

const automationMediaSchema = z
  .object({
    asset_path: z.string().min(1).max(500),
    kind: z.enum(["image", "video", "audio", "document"]),
    mime: z.string().min(3).max(150),
    size_bytes: z.number().int().positive().max(50 * 1024 * 1024),
    caption_template: z.string().max(2000).optional(),
    sequence_key: z.string().min(1).max(120).optional(),
  })
  .superRefine((media, ctx) => {
    const mime = media.mime.split(";")[0]!.trim().toLowerCase();
    const compatible =
      (media.kind === "image" && mime.startsWith("image/")) ||
      (media.kind === "video" && mime.startsWith("video/")) ||
      (media.kind === "audio" && mime.startsWith("audio/")) ||
      (media.kind === "document" && !mime.startsWith("image/") && !mime.startsWith("video/") && !mime.startsWith("audio/"));
    if (!compatible) ctx.addIssue({ code: "custom", path: ["mime"], message: "MIME incompatível com kind" });
    if (media.asset_path.includes("..")) ctx.addIssue({ code: "custom", path: ["asset_path"], message: "asset_path inválido" });
  });

const sendWhatsappConfigSchema = z
  .object({
    channel_session_id: z.string().uuid(),
    template: z.string().min(1).max(2000).optional(),
    media: automationMediaSchema.optional(),
  })
  .refine((config) => Boolean(config.template || config.media), {
    message: "template ou media obrigatório",
  });

export const actionSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("create_or_move_lead"), config: z.object({ pipeline_id: z.string().uuid(), stage_id: z.string().uuid() }) }),
  z.object({ type: z.literal("send_whatsapp_message"), config: sendWhatsappConfigSchema }),
  z.object({ type: z.literal("add_tag"), config: z.object({ tags: z.array(z.string().min(1).max(60)).min(1).max(10) }) }),
  z.object({ type: z.literal("assign_owner"), config: z.object({ user_id: z.string().uuid() }) }),
  z.object({
    type: z.literal("call_webhook"),
    config: z.object({
      url: z.string().url().max(2000),
      // Input do usuário (plaintext, write-only) — a rota troca por secret_enc.
      secret: z.string().max(200).optional(),
      // Ciphertext hex (round-trip do editor: GET devolve, PATCH preserva).
      secret_enc: z.string().max(4000).optional(),
    }),
  }),
]);

export const createWebhookSourceSchema = z.object({
  name: z.string().min(1).max(120),
  default_pipeline_id: z.string().uuid(),
  default_stage_id: z.string().uuid(),
  redirect_to: z.string().url().max(2000).nullish(),
  field_map: z
    .object({
      name: z.array(z.string()).optional(),
      phone: z.array(z.string()).optional(),
      email: z.array(z.string()).optional(),
    })
    .optional(),
  secret: z.string().min(16).max(200).nullish(),
  daily_new_contact_limit: z.number().int().min(1).max(10_000).default(30),
  quota_timezone: z.string().min(1).max(100).default("UTC"),
});
export const updateWebhookSourceSchema = createWebhookSourceSchema.partial().extend({
  is_active: z.boolean().optional(),
});

export const createAutomationRuleSchema = z.object({
  name: z.string().min(1).max(120),
  trigger_event: z.enum(TRIGGER_EVENTS),
  conditions: z.array(conditionSchema).max(10).default([]),
  actions: z.array(actionSchema).min(1).max(10),
});
export const updateAutomationRuleSchema = createAutomationRuleSchema.partial().extend({
  is_active: z.boolean().optional(),
});

export type CreateWebhookSourceInput = z.infer<typeof createWebhookSourceSchema>;
export type UpdateWebhookSourceInput = z.infer<typeof updateWebhookSourceSchema>;
export type CreateAutomationRuleInput = z.infer<typeof createAutomationRuleSchema>;
export type UpdateAutomationRuleInput = z.infer<typeof updateAutomationRuleSchema>;
