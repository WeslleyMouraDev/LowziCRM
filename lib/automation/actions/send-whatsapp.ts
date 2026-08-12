import { registerAction } from "@/lib/automation/actions";
import type { ActionCtx, ActionResultDetail } from "@/lib/automation/types";
import { renderTemplate } from "@/lib/automation/template";
import { ensureConversation } from "@/lib/automation/start-conversation";
import {
  AUTOMATED_SEND_SPACING_MS,
  checkDailyLimit,
  jitterMs,
  nextWindowStart,
  withinSendWindow,
} from "@/lib/automation/throttle";
import { sendMessageHandler } from "@/app/api/v1/messages/_handler";

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

// Espaçamento entre envios automatizados DENTRO do mesmo tick do drain,
// por sessão (estado de módulo — suficiente p/ instância única do cron).
const _lastSendAt = new Map<string, number>();

async function postponeUntil(ctx: ActionCtx, config: Record<string, unknown>): Promise<string | null> {
  if (!withinSendWindow()) return nextWindowStart();
  const sessionId = typeof config.channel_session_id === "string" ? config.channel_session_id : null;
  if (!sessionId) return null; // config inválida falha no execute, não adia
  const daily = await checkDailyLimit(ctx.admin, ctx.organizationId, sessionId);
  return daily.allowed ? null : (daily.retry_at ?? null);
}

async function execute(ctx: ActionCtx, config: Record<string, unknown>): Promise<ActionResultDetail> {
  const sessionId = typeof config.channel_session_id === "string" ? config.channel_session_id : null;
  const media = config.media && typeof config.media === "object" ? config.media as Record<string, unknown> : null;
  const template = typeof config.template === "string"
    ? config.template
    : typeof media?.caption_template === "string"
      ? media.caption_template
      : null;
  const mediaStoragePath = typeof media?.asset_path === "string"
    ? media.asset_path
    : typeof config.media_storage_path === "string"
      ? config.media_storage_path
      : null;
  const mediaMime = typeof media?.mime === "string"
    ? media.mime
    : typeof config.media_mime === "string"
      ? config.media_mime
      : null;
  const mediaSizeBytes = typeof media?.size_bytes === "number"
    ? media.size_bytes
    : typeof config.media_size_bytes === "number"
      ? config.media_size_bytes
      : null;
  const configuredMediaType = media?.kind ?? config.media_type;
  const mediaType = ["image", "video", "audio", "document"].includes(String(configuredMediaType))
    ? String(configuredMediaType)
    : null;
  const configuredSequenceKey = media?.sequence_key ?? config.sequence_key;
  const sequenceKey = typeof configuredSequenceKey === "string" ? configuredSequenceKey : (mediaStoragePath ?? "text");
  if (!sessionId || (!template && !mediaStoragePath)) {
    return { type: "send_whatsapp_message", status: "failed", error: "missing_config" };
  }
  if (mediaStoragePath && (!mediaType || !mediaMime || !mediaSizeBytes)) {
    return { type: "send_whatsapp_message", status: "failed", error: "invalid_media_config" };
  }
  if (mediaStoragePath && !mediaStoragePath.startsWith(`${ctx.organizationId}/automation-assets/`)) {
    return { type: "send_whatsapp_message", status: "failed", error: "invalid_media_path" };
  }
  const contact = ctx.context.contact as { id: string; is_blocked?: boolean; phone_number?: string | null } | undefined;
  if (!contact) return { type: "send_whatsapp_message", status: "skipped", detail: { reason: "no_contact" } };
  if (contact.is_blocked) return { type: "send_whatsapp_message", status: "skipped", detail: { reason: "contact_blocked" } };
  if (!contact.phone_number) return { type: "send_whatsapp_message", status: "skipped", detail: { reason: "no_phone" } };

  try {
    const conversationId = await ensureConversation(ctx.admin, ctx.organizationId, contact.id, sessionId);
    const { data: conversation, error: conversationError } = await ctx.admin
      .from("conversations")
      .select("assigned_to_user_id, assignee_kind")
      .eq("id", conversationId)
      .eq("organization_id", ctx.organizationId)
      .maybeSingle();
    if (conversationError) throw new Error(conversationError.message);
    if (conversation?.assigned_to_user_id || conversation?.assignee_kind === "user") {
      return { type: "send_whatsapp_message", status: "skipped", detail: { reason: "human_attending" } };
    }

    const idempotencyKey = `${ctx.ruleId}:${ctx.event.id}:${sequenceKey}`;
    const { data: priorRows, error: priorError } = await ctx.admin
      .from("messages")
      .select("id, metadata")
      .eq("organization_id", ctx.organizationId)
      .eq("conversation_id", conversationId)
      .limit(100);
    if (priorError) throw new Error(priorError.message);
    const prior = (priorRows ?? []).find((row: { metadata?: Record<string, unknown> | null }) =>
      row.metadata?.automation_idempotency_key === idempotencyKey,
    );
    if (prior) {
      return {
        type: "send_whatsapp_message",
        status: "skipped",
        detail: { reason: "idempotent_replay", message_id: prior.id, conversation_id: conversationId },
      };
    }

    const last = _lastSendAt.get(sessionId) ?? 0;
    const wait = last + AUTOMATED_SEND_SPACING_MS + jitterMs() - Date.now();
    if (wait > 0) await sleep(wait);
    _lastSendAt.set(sessionId, Date.now());

    const body = template ? renderTemplate(template, ctx.context) : undefined;
    const message = await sendMessageHandler(
      ctx.admin,
      {
        organization_id: ctx.organizationId,
        actor: { type: "webhook_source", id: ctx.ruleId },
        requestId: `rule:${ctx.ruleId}`,
      },
      {
        conversation_id: conversationId,
        type: mediaType ?? "text",
        ...(body ? { body } : {}),
        ...(mediaStoragePath
          ? {
              media_storage_path: mediaStoragePath,
              media_mime: mediaMime!,
              media_size_bytes: mediaSizeBytes!,
            }
          : {}),
        metadata: {
          automation_idempotency_key: idempotencyKey,
          automation_event_id: ctx.event.id,
          automation_sequence_key: sequenceKey,
        },
      } as Parameters<typeof sendMessageHandler>[2],
    );
    const meta = (message as { metadata?: Record<string, unknown> }).metadata ?? {};
    return {
      type: "send_whatsapp_message",
      status: "success",
      detail: {
        message_id: (message as { id: string }).id,
        conversation_id: conversationId,
        ...(meta.queued_reason ? { queued_reason: meta.queued_reason } : {}),
      },
    };
  } catch (err) {
    return {
      type: "send_whatsapp_message",
      status: "failed",
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

registerAction({ type: "send_whatsapp_message", postponeUntil, execute });
