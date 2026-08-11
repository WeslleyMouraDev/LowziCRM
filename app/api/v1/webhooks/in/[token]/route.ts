/**
 * POST /api/v1/webhooks/in/[token] — captação pública de leads.
 *
 * Mesmo padrão do webhook WAHA per-tenant: path_token resolve o tenant
 * (fonte confiável — nunca o body), loga em webhook_events_log e NÃO executa
 * ação síncrona além de criar o lead (motor de regras consome lead.created
 * via event_log). Aceita JSON e form-urlencoded na mesma URL.
 */
import { randomUUID } from "node:crypto";
import { NextResponse, type NextRequest } from "next/server";

import { fail, ok } from "@/lib/api/wrappers";
import { audit } from "@/lib/audit";
import { checkRateLimit } from "@/lib/ai/dispatcher/rate-limit";
import { logger } from "@/lib/logger";
import { createAdminClient } from "@/lib/supabase/admin";
import { createLeadHandler } from "@/app/api/v1/leads/_handler";
import type { CreateLeadInput } from "@/lib/schemas";
import { mapInboundPayload, verifyInboundSignature, type FieldMap } from "@/lib/webhooks/inbound";
import { decryptWebhookSecret } from "@/lib/webhooks/secrets";
import { ApiError } from "@/lib/api/types";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

interface RouteCtx {
  params: Promise<{ token: string }>;
}

const RATE_LIMIT_PER_MIN = 60;

// ponytail: mirrors the default phone aliases in lib/webhooks/inbound.ts —
// duplicated (not exported there) only so the route can flag a phone-looking
// field that failed normalizePhoneBR, for observability. Keep in sync if that
// list changes.
const PHONE_ALIASES_FOR_LOGGING = ["phone", "telefone", "whatsapp", "celular", "phone_number", "tel"];

function findRawPhoneIfUnnormalized(payload: Record<string, unknown>, fieldMap: FieldMap): string | null {
  const aliases = [...(fieldMap.phone ?? []), ...PHONE_ALIASES_FOR_LOGGING];
  const lowered = new Map(Object.keys(payload).map((k) => [k.toLowerCase(), k]));
  for (const alias of aliases) {
    const key = lowered.get(alias.toLowerCase());
    if (key !== undefined) {
      const v = payload[key];
      if (typeof v === "string" && v.trim()) return v.trim();
    }
  }
  return null;
}

export async function POST(req: NextRequest, ctx: RouteCtx): Promise<NextResponse> {
  const requestId = randomUUID();
  const { token } = await ctx.params;
  if (!token || token.length < 8) {
    return fail("not_found", "unknown webhook token", 404, { requestId });
  }

  const rl = await checkRateLimit(`webhook_in:${token}`, RATE_LIMIT_PER_MIN, 60);
  if (!rl.allowed) {
    return fail("rate_limited", "Too many requests.", 429, {
      requestId,
      headers: { "Retry-After": "60" },
    });
  }

  const admin = createAdminClient();
  const { data: source, error: srcErr } = await admin
    .from("webhook_sources")
    .select(
      "id, organization_id, secret_encrypted, default_pipeline_id, default_stage_id, field_map, redirect_to, is_active, daily_new_contact_limit, quota_timezone",
    )
    .eq("path_token", token)
    .maybeSingle();
  if (srcErr) return fail("internal_error", srcErr.message, 500, { requestId });
  if (!source || !source.is_active) {
    return fail("not_found", "unknown webhook token", 404, { requestId });
  }

  const rawBody = await req.text();
  const contentType = req.headers.get("content-type") ?? "";
  const isForm = contentType.includes("application/x-www-form-urlencoded");
  let payload: Record<string, unknown>;
  if (isForm) {
    payload = Object.fromEntries(new URLSearchParams(rawBody));
  } else {
    try {
      payload = rawBody ? (JSON.parse(rawBody) as Record<string, unknown>) : {};
    } catch {
      return fail("invalid_request", "invalid_json", 400, { requestId });
    }
  }

  const sigHeader = req.headers.get("x-deskcomm-signature");
  // secret cifrado at-rest (migration 0041). Decrypt falhou (chave da GUC
  // ausente/trocada)? Precedente WAHA: pula a validação em vez de derrubar a
  // captação — secret aqui é defesa opcional, não gate de disponibilidade.
  let sourceSecret: string | null = null;
  let hmacSkipped = false;
  if (source.secret_encrypted) {
    sourceSecret = await decryptWebhookSecret(admin, source.secret_encrypted as unknown as string);
    if (sourceSecret === null) hmacSkipped = true;
  }
  const validSignature = sourceSecret ? verifyInboundSignature(rawBody, sigHeader, sourceSecret) : null;
  if (sourceSecret && !validSignature) {
    await audit({
      action: "webhook.inbound_invalid_signature",
      organizationId: source.organization_id,
      resourceType: "webhook_source",
      resourceId: source.id,
      requestId,
    });
    return fail("unauthenticated", "invalid_signature", 401, { requestId });
  }

  const headersJson: Record<string, string> = {};
  req.headers.forEach((value, key) => {
    const k = key.toLowerCase();
    if (k.startsWith("authorization") || k === "cookie") return;
    headersJson[key] = value;
  });
  await admin.from("webhook_events_log").insert({
    organization_id: source.organization_id,
    provider: "generic",
    webhook_path_token: token,
    http_method: "POST",
    headers: headersJson,
    raw_body: rawBody,
    payload_parsed: payload,
    signature_header: sigHeader ?? null,
    // hmacSkipped (decrypt indisponível) conta como "não validado mas aceito",
    // igual ao webhook WAHA — o feed da UI não pinta de vermelho.
    valid_signature: validSignature ?? true,
    event_type: hmacSkipped ? "lead_capture.received_hmac_skipped" : "lead_capture.received",
    external_id: null,
    status: "received",
    attempts: 0,
  });

  // Idempotência (spec §5): `external_id` é campo reservado do envio — quem
  // integra via sistema (Zapier/n8n/loja) manda o ID único do disparo e o
  // reenvio automático (retry por timeout) NUNCA duplica o lead. O índice
  // uniq_crm_leads_org_source_external garante a corrida; aqui vai o fast-path.
  const externalIdRaw = payload["external_id"];
  const externalId =
    typeof externalIdRaw === "string" && externalIdRaw.trim() ? externalIdRaw.trim().slice(0, 255) : null;

  const respondWithLead = (leadId: string): NextResponse => {
    if (isForm && source.redirect_to) {
      return NextResponse.redirect(source.redirect_to as string, 303);
    }
    return ok({ lead_id: leadId }, { requestId });
  };

  const findLeadByExternalId = async (): Promise<string | null> => {
    if (!externalId) return null;
    const { data } = await admin
      .from("crm_leads")
      .select("id")
      .eq("organization_id", source.organization_id)
      .eq("source", "webhook")
      .eq("external_id", externalId)
      .maybeSingle();
    return (data?.id as string | undefined) ?? null;
  };

  const dedupedLeadId = await findLeadByExternalId();
  if (dedupedLeadId) {
    // Mesmo envio repetido: 200 com o lead existente, nada é recriado — a
    // ferramenta que reenviou recebe sucesso e para de tentar.
    return respondWithLead(dedupedLeadId);
  }

  const fieldMap = (source.field_map ?? {}) as FieldMap;
  // external_id não é dado do lead — sai do payload antes do mapeamento pra
  // não virar custom_field (o log de recebimento acima preserva o original).
  const { external_id: _reservedExternalId, ...payloadForMapping } = payload;
  const mapped = mapInboundPayload(externalId ? payloadForMapping : payload, fieldMap);
  if (!mapped.phone) {
    const rawPhone = findRawPhoneIfUnnormalized(payload, fieldMap);
    if (rawPhone) mapped.source_metadata.raw_phone = rawPhone;
  }
  if (!mapped.name && !mapped.phone && !mapped.email) {
    return fail("invalid_request", "Nenhum campo mapeável (nome/telefone/email).", 400, { requestId });
  }

  // Contato + quota: uma RPC transacional resolve contato existente sem custo,
  // reserva a vaga diária sob advisory lock e cria o contato na MESMA transação.
  // O teto do Actor controla custo; este gate no banco controla a operação.
  let contactId: string | undefined;
  if (mapped.phone) {
    const { data: reservationRows, error: reservationErr } = await admin.rpc(
      "reserve_webhook_new_contact" as never,
      {
        p_organization_id: source.organization_id,
        p_webhook_source_id: source.id,
        p_phone: mapped.phone,
        p_name: mapped.name ?? mapped.phone,
        p_email: mapped.email,
        p_source_metadata: mapped.source_metadata,
        p_daily_limit: source.daily_new_contact_limit,
        p_timezone: source.quota_timezone,
      } as never,
    );

    if (reservationErr) {
      logger.error("[webhooks.inbound] contact quota reservation failed", {
        webhookSourceId: source.id,
        organizationId: source.organization_id,
        errorCode: reservationErr.code,
        errorMessage: reservationErr.message,
      });
      return fail("internal_error", "contact_quota_reservation_failed", 500, { requestId });
    }

    const reservation = Array.isArray(reservationRows) ? reservationRows[0] : reservationRows;
    if (!reservation) {
      return fail("internal_error", "contact_quota_empty_result", 500, { requestId });
    }
    const quota = reservation as unknown as {
      contact_id: string | null;
      created: boolean;
      quota_exceeded: boolean;
      used_count: number;
      quota_date: string;
    };
    if (quota.quota_exceeded) {
      await audit({
        action: "webhook.daily_new_contact_quota_exceeded",
        organizationId: source.organization_id,
        resourceType: "webhook_source",
        resourceId: source.id,
        requestId,
        metadata: {
          quota_date: quota.quota_date,
          used_count: quota.used_count,
          limit: source.daily_new_contact_limit,
          timezone: source.quota_timezone,
        },
      });
      return fail("rate_limited", "daily_new_contact_quota_exceeded", 429, {
        requestId,
        headers: { "Retry-After": "3600" },
      });
    }
    contactId = quota.contact_id ?? undefined;
  }

  const leadInput: CreateLeadInput & {
    custom_fields?: Record<string, unknown>;
    source_metadata?: Record<string, unknown>;
    external_id?: string;
  } = {
    pipeline_id: source.default_pipeline_id,
    stage_id: source.default_stage_id,
    title: mapped.name ?? mapped.phone ?? mapped.email ?? "Lead sem nome",
    contact_id: contactId,
    currency: "BRL",
    tags: [],
    source: "webhook",
    custom_fields: mapped.custom_fields,
    source_metadata: { webhook_source_id: source.id, ...mapped.source_metadata },
    ...(externalId ? { external_id: externalId } : {}),
  };

  let lead: Record<string, unknown>;
  try {
    lead = await createLeadHandler(
      admin,
      {
        organization_id: source.organization_id,
        actor: { type: "webhook_source", id: source.id },
        requestId,
      },
      leadInput,
    );
  } catch (err) {
    if (err instanceof ApiError) {
      // Corrida do retry: dois POSTs simultâneos com o mesmo external_id
      // passam ambos pelo fast-path; o índice único derruba o segundo INSERT
      // (23505) — re-seleciona o vencedor e responde idempotente.
      if (externalId && err.message?.includes("uniq_crm_leads_org_source_external")) {
        const winnerId = await findLeadByExternalId();
        if (winnerId) return respondWithLead(winnerId);
      }
      return fail(err.code, err.message ?? "erro", err.status, { requestId });
    }
    throw err;
  }

  await admin
    .from("webhook_sources")
    .update({ last_received_at: new Date().toISOString() })
    .eq("id", source.id);

  await audit({
    action: "webhook.lead_received",
    organizationId: source.organization_id,
    resourceType: "crm_lead",
    resourceId: String(lead.id),
    requestId,
    metadata: { webhook_source_id: source.id },
  });

  return respondWithLead(String(lead.id));
}
