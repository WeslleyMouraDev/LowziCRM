#!/usr/bin/env python3
"""Verifica concorrência da quota usando uma data futura e remove tudo ao final."""

from __future__ import annotations

import json
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor

DB_URL = os.environ.get("SUPABASE_DB_URL")
ORG_ID = os.environ.get("QUOTA_VERIFY_ORG_ID")
SOURCE_ID = os.environ.get("QUOTA_VERIFY_SOURCE_ID")
TEST_DATE = os.environ.get("QUOTA_VERIFY_DATE", "2098-01-20")
MARKER = "task4-concurrency-verification"

if not DB_URL or not ORG_ID or not SOURCE_ID:
    raise SystemExit("Defina SUPABASE_DB_URL, QUOTA_VERIFY_ORG_ID e QUOTA_VERIFY_SOURCE_ID")


def psql(sql: str) -> str:
    result = subprocess.run(
        ["psql", DB_URL, "-X", "-v", "ON_ERROR_STOP=1", "-tA", "-f", "-"],
        input=sql,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"psql saiu com {result.returncode}")
    return result.stdout.strip()


def reserve(phone: str) -> dict[str, object]:
    raw = psql(
        f"""
        select row_to_json(r) from public.reserve_webhook_new_contact(
          '{ORG_ID}'::uuid, '{SOURCE_ID}'::uuid, '{phone}',
          'Task4 concorrência', null,
          '{{"task4_verification":"{MARKER}"}}'::jsonb,
          30, 'America/Recife', '{TEST_DATE} 15:00:00+00'::timestamptz
        ) r;
        """
    )
    return json.loads(raw)


def cleanup() -> None:
    psql(
        f"""
        delete from public.contacts
         where organization_id = '{ORG_ID}'::uuid
           and source_metadata->>'task4_verification' = '{MARKER}';
        delete from public.webhook_daily_new_contact_quota
         where organization_id = '{ORG_ID}'::uuid
           and webhook_source_id = '{SOURCE_ID}'::uuid
           and quota_date = '{TEST_DATE}'::date;
        """
    )


try:
    cleanup()
    for index in range(29):
        row = reserve(f"+55810003{index:04d}")
        if not row["created"] or row["quota_exceeded"]:
            raise RuntimeError(f"prefill falhou no índice {index}: {row}")

    with ThreadPoolExecutor(max_workers=2) as executor:
        rows = list(executor.map(reserve, ["+558100039998", "+558100039999"]))

    created = [row for row in rows if row["created"]]
    denied = [row for row in rows if row["quota_exceeded"]]
    used = int(
        psql(
            f"""
            select used_count from public.webhook_daily_new_contact_quota
             where organization_id = '{ORG_ID}'::uuid
               and webhook_source_id = '{SOURCE_ID}'::uuid
               and quota_date = '{TEST_DATE}'::date;
            """
        )
    )
    contacts = int(
        psql(
            f"""
            select count(*) from public.contacts
             where organization_id = '{ORG_ID}'::uuid
               and source_metadata->>'task4_verification' = '{MARKER}';
            """
        )
    )
    messages = int(
        psql(
            f"""
            select count(*) from public.messages m
             join public.contacts c on c.id = m.contact_id
            where c.organization_id = '{ORG_ID}'::uuid
              and c.source_metadata->>'task4_verification' = '{MARKER}';
            """
        )
    )

    if len(created) != 1 or len(denied) != 1 or used != 30 or contacts != 30 or messages != 0:
        raise RuntimeError(
            json.dumps(
                {"rows": rows, "used_count": used, "contacts": contacts, "messages": messages},
                ensure_ascii=False,
            )
        )

    print(
        json.dumps(
            {
                "ok": True,
                "concurrent_created": 1,
                "concurrent_denied": 1,
                "used_count": used,
                "synthetic_contacts": contacts,
                "messages_created": messages,
                "cleanup": "pending-finally",
            },
            indent=2,
        )
    )
finally:
    cleanup()
