-- 0116 — quota diária transacional de novos contatos por webhook
--
-- Garante no PostgreSQL (não só no Actor/coletor) que retries e concorrência
-- não ultrapassem o teto configurado por fonte. O dia é calculado no timezone
-- da operação; a reserva e a criação do contato compartilham a mesma transação.

alter table public.webhook_sources
  add column if not exists daily_new_contact_limit integer not null default 30,
  add column if not exists quota_timezone text not null default 'UTC';

alter table public.webhook_sources
  drop constraint if exists webhook_sources_daily_new_contact_limit_check;
alter table public.webhook_sources
  add constraint webhook_sources_daily_new_contact_limit_check
  check (daily_new_contact_limit between 1 and 10000);

create table if not exists public.webhook_daily_new_contact_quota (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  webhook_source_id uuid not null references public.webhook_sources(id) on delete cascade,
  quota_date date not null,
  used_count integer not null default 0 check (used_count >= 0),
  limit_snapshot integer not null check (limit_snapshot > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (organization_id, webhook_source_id, quota_date)
);

create index if not exists idx_webhook_daily_quota_source_date
  on public.webhook_daily_new_contact_quota (webhook_source_id, quota_date desc);

alter table public.webhook_daily_new_contact_quota enable row level security;

create or replace function public.reserve_webhook_new_contact(
  p_organization_id uuid,
  p_webhook_source_id uuid,
  p_phone text,
  p_name text,
  p_email text,
  p_source_metadata jsonb,
  p_daily_limit integer,
  p_timezone text,
  p_now timestamptz default now()
) returns table (
  contact_id uuid,
  created boolean,
  quota_exceeded boolean,
  used_count integer,
  quota_date date
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_contact_id uuid;
  v_quota_date date;
  v_used integer;
begin
  if p_phone is null or btrim(p_phone) = '' then
    raise exception using errcode = '22023', message = 'phone_required';
  end if;
  if p_daily_limit is null or p_daily_limit < 1 or p_daily_limit > 10000 then
    raise exception using errcode = '22023', message = 'invalid_daily_limit';
  end if;
  if not exists (
    select 1
      from public.webhook_sources ws
     where ws.id = p_webhook_source_id
       and ws.organization_id = p_organization_id
       and ws.is_active
  ) then
    raise exception using errcode = '22023', message = 'invalid_webhook_source';
  end if;

  -- Falha cedo para timezone IANA inválido e usa o dia comercial local.
  v_quota_date := (p_now at time zone p_timezone)::date;

  -- Serializa a identidade do contato entre fontes para que duas fontes não
  -- cobrem duas vagas pelo mesmo telefone novo.
  perform pg_advisory_xact_lock(
    hashtextextended('webhook-contact:' || p_organization_id::text || ':' || p_phone, 0)
  );

  select c.id into v_contact_id
    from public.contacts c
   where c.organization_id = p_organization_id
     and c.phone_number = p_phone
     and c.is_merged_into is null
   limit 1;

  if v_contact_id is not null then
    select q.used_count into v_used
      from public.webhook_daily_new_contact_quota q
     where q.organization_id = p_organization_id
       and q.webhook_source_id = p_webhook_source_id
       and q.quota_date = v_quota_date;
    return query select v_contact_id, false, false, coalesce(v_used, 0), v_quota_date;
    return;
  end if;

  -- Uma única fila por fonte/dia torna o check+increment atômico inclusive
  -- quando telefones diferentes disputam a última vaga.
  perform pg_advisory_xact_lock(
    hashtextextended(
      'webhook-quota:' || p_organization_id::text || ':' ||
      p_webhook_source_id::text || ':' || v_quota_date::text,
      0
    )
  );

  insert into public.webhook_daily_new_contact_quota (
    organization_id, webhook_source_id, quota_date, used_count, limit_snapshot
  ) values (
    p_organization_id, p_webhook_source_id, v_quota_date, 1, p_daily_limit
  )
  on conflict on constraint webhook_daily_new_contact_quota_pkey
  do update set
    used_count = public.webhook_daily_new_contact_quota.used_count + 1,
    limit_snapshot = excluded.limit_snapshot,
    updated_at = now()
  where public.webhook_daily_new_contact_quota.used_count < p_daily_limit
  returning public.webhook_daily_new_contact_quota.used_count into v_used;

  if v_used is null then
    select q.used_count into v_used
      from public.webhook_daily_new_contact_quota q
     where q.organization_id = p_organization_id
       and q.webhook_source_id = p_webhook_source_id
       and q.quota_date = v_quota_date;
    return query select null::uuid, false, true, coalesce(v_used, p_daily_limit), v_quota_date;
    return;
  end if;

  insert into public.contacts (
    organization_id,
    name,
    phone_number,
    email,
    source,
    source_metadata
  ) values (
    p_organization_id,
    coalesce(nullif(btrim(p_name), ''), p_phone),
    p_phone,
    nullif(btrim(p_email), ''),
    'webhook',
    jsonb_build_object('webhook_source_id', p_webhook_source_id) || coalesce(p_source_metadata, '{}'::jsonb)
  ) returning id into v_contact_id;

  return query select v_contact_id, true, false, v_used, v_quota_date;
end;
$$;

revoke all on function public.reserve_webhook_new_contact(uuid, uuid, text, text, text, jsonb, integer, text, timestamptz) from public;
revoke execute on function public.reserve_webhook_new_contact(uuid, uuid, text, text, text, jsonb, integer, text, timestamptz) from anon, authenticated;
grant execute on function public.reserve_webhook_new_contact(uuid, uuid, text, text, text, jsonb, integer, text, timestamptz) to service_role;

notify pgrst, 'reload schema';
