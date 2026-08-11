import { spawn } from "node:child_process";
import { beforeAll, describe, expect, it } from "vitest";

import { GOV_ORG, GOV_PIPELINE, GOV_STAGE, seedGov, sql } from "./gov-helpers";

const container = process.env.TEST_DB_CONTAINER;
if (!container) throw new Error("TEST_DB_CONTAINER ausente — execute via pnpm test:invariants");

const containerName: string = container;

const SOURCE_ID = "76000000-0000-4000-8000-000000000004";
const SOURCE_2_ID = "76000000-0000-4000-8000-000000000005";

interface QuotaResult {
  contact_id: string | null;
  created: boolean;
  quota_exceeded: boolean;
  used_count: number;
  quota_date: string;
}

function reserve(args: {
  sourceId?: string;
  phone: string;
  now?: string;
  limit?: number;
}): QuotaResult {
  const out = sql(`
    select row_to_json(r) from public.reserve_webhook_new_contact(
      '${GOV_ORG}'::uuid,
      '${args.sourceId ?? SOURCE_ID}'::uuid,
      '${args.phone}',
      'Contato quota',
      null,
      '{"fixture":"quota"}'::jsonb,
      ${args.limit ?? 30},
      'America/Recife',
      '${args.now ?? "2026-08-11T15:00:00Z"}'::timestamptz
    ) r;
  `);
  return JSON.parse(out) as QuotaResult;
}

function concurrentReserve(phone: string): Promise<{ status: number; stdout: string; stderr: string }> {
  const script = `select row_to_json(r) from public.reserve_webhook_new_contact(
    '${GOV_ORG}'::uuid, '${SOURCE_ID}'::uuid, '${phone}', 'Concorrente', null,
    '{}'::jsonb, 30, 'America/Recife', '2026-08-14T15:00:00Z'::timestamptz
  ) r;`;
  return new Promise((resolve) => {
    const child = spawn(
      "docker",
      ["exec", "-i", containerName, "psql", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-tA", "-f", "-"],
      { stdio: ["pipe", "pipe", "pipe"] },
    );
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk: Buffer) => (stdout += String(chunk)));
    child.stderr.on("data", (chunk: Buffer) => (stderr += String(chunk)));
    child.on("close", (status: number | null) => resolve({ status: status ?? 1, stdout: stdout.trim(), stderr }));
    child.stdin.end(script);
  });
}

beforeAll(() => {
  seedGov();
  sql(`
    insert into public.webhook_sources (
      id, organization_id, name, path_token, default_pipeline_id, default_stage_id,
      is_active, daily_new_contact_limit, quota_timezone
    ) values
      ('${SOURCE_ID}', '${GOV_ORG}', 'Quota A', 'quota-source-a', '${GOV_PIPELINE}', '${GOV_STAGE}', true, 30, 'America/Recife'),
      ('${SOURCE_2_ID}', '${GOV_ORG}', 'Quota B', 'quota-source-b', '${GOV_PIPELINE}', '${GOV_STAGE}', true, 30, 'America/Recife')
    on conflict (id) do update set
      daily_new_contact_limit = excluded.daily_new_contact_limit,
      quota_timezone = excluded.quota_timezone;
  `);
});

describe("quota diária transacional de novos contatos por webhook", () => {
  it("aceita contatos 1–30 e bloqueia explicitamente o 31º", () => {
    const day = "2026-08-11T15:00:00Z";
    const accepted = Array.from({ length: 30 }, (_, i) => reserve({
      phone: `+55818881${String(i).padStart(4, "0")}`,
      now: day,
    }));
    const denied = reserve({ phone: "+558188819999", now: day });

    expect(accepted.every((row) => row.created && !row.quota_exceeded)).toBe(true);
    expect(accepted.at(-1)?.used_count).toBe(30);
    expect(denied).toMatchObject({ contact_id: null, created: false, quota_exceeded: true, used_count: 30 });
    expect(Number(sql(`select count(*) from public.contacts where source_metadata->>'webhook_source_id'='${SOURCE_ID}' and source_metadata->>'fixture'='quota';`))).toBe(30);
  });

  it("retry e contato já existente não consomem uma nova unidade", () => {
    const first = reserve({ phone: "+558188820001", now: "2026-08-12T15:00:00Z" });
    const retry = reserve({ phone: "+558188820001", now: "2026-08-12T15:00:00Z" });
    const otherSource = reserve({ sourceId: SOURCE_2_ID, phone: "+558188820001", now: "2026-08-12T15:00:00Z" });

    expect(first).toMatchObject({ created: true, used_count: 1, quota_exceeded: false });
    expect(retry).toMatchObject({ contact_id: first.contact_id, created: false, quota_exceeded: false });
    expect(otherSource).toMatchObject({ contact_id: first.contact_id, created: false, quota_exceeded: false, used_count: 0 });
    expect(Number(sql(`select used_count from public.webhook_daily_new_contact_quota where webhook_source_id='${SOURCE_ID}' and quota_date='2026-08-12';`))).toBe(1);
    expect(Number(sql(`select count(*) from public.webhook_daily_new_contact_quota where webhook_source_id='${SOURCE_2_ID}' and quota_date='2026-08-12';`))).toBe(0);
  });

  it("duas requisições concorrentes disputando a última vaga criam somente um contato", async () => {
    for (let i = 0; i < 29; i += 1) {
      reserve({ phone: `+55818883${String(i).padStart(4, "0")}`, now: "2026-08-14T15:00:00Z" });
    }
    const [a, b] = await Promise.all([
      concurrentReserve("+558188839998"),
      concurrentReserve("+558188839999"),
    ]);
    expect(a.status).toBe(0);
    expect(b.status).toBe(0);
    const rows = [JSON.parse(a.stdout), JSON.parse(b.stdout)] as QuotaResult[];
    expect(rows.filter((row) => row.created)).toHaveLength(1);
    expect(rows.filter((row) => row.quota_exceeded)).toHaveLength(1);
    expect(Number(sql(`select used_count from public.webhook_daily_new_contact_quota where webhook_source_id='${SOURCE_ID}' and quota_date='2026-08-14';`))).toBe(30);
  });

  it("vira o dia conforme America/Recife, não conforme UTC", () => {
    const beforeMidnight = reserve({ phone: "+558188840001", now: "2026-08-16T02:59:59Z", limit: 1 });
    const afterMidnight = reserve({ phone: "+558188840002", now: "2026-08-16T03:00:00Z", limit: 1 });

    expect(beforeMidnight.quota_date).toBe("2026-08-15");
    expect(afterMidnight.quota_date).toBe("2026-08-16");
    expect(beforeMidnight.created).toBe(true);
    expect(afterMidnight.created).toBe(true);
  });

  it("função não fica executável por anon ou authenticated", () => {
    const acl = sql(`
      select
        has_function_privilege('anon', 'public.reserve_webhook_new_contact(uuid,uuid,text,text,text,jsonb,integer,text,timestamptz)', 'execute')::int || ',' ||
        has_function_privilege('authenticated', 'public.reserve_webhook_new_contact(uuid,uuid,text,text,text,jsonb,integer,text,timestamptz)', 'execute')::int || ',' ||
        has_function_privilege('service_role', 'public.reserve_webhook_new_contact(uuid,uuid,text,text,text,jsonb,integer,text,timestamptz)', 'execute')::int;
    `);
    expect(acl).toBe("0,0,1");
  });
});
