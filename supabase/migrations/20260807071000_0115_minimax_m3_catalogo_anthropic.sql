-- 0115 — MiniMax M3 no catálogo do provider `anthropic`
--
-- Esta instalação direciona o SDK Anthropic-compatible para
-- https://api.minimax.io/anthropic. Portanto, oferecer ids `claude-*` na tela
-- cria agentes que só falham na primeira chamada. O id abaixo foi exercitado
-- contra POST /anthropic/v1/messages em 07/08/2026.
--
-- O sufixo [1m] é o id recomendado pela documentação oficial do Token Plan;
-- a resposta da API normaliza `model` para MiniMax-M3.
-- Preços em centavos de dólar / milhão de tokens, conforme Pay as You Go
-- Standard (desconto permanente vigente): US$0,30 entrada e US$1,20 saída
-- para entradas de até 512k. O orçamento usa a tarifa desse patamar normal.

-- O índice parcial permite só um default por provider: desmarcar primeiro.
update public.ai_models
   set is_default_for_provider = false
 where provider = 'anthropic'
   and is_default_for_provider;

-- Modelos Claude não são válidos no endpoint MiniMax e não devem aparecer no
-- formulário. Mantê-los como depreciados preserva referências históricas.
update public.ai_models
   set deprecated_at = coalesce(deprecated_at, now())
 where provider = 'anthropic'
   and model_id <> 'MiniMax-M3[1m]';

insert into public.ai_models
  (provider, model_id, display_name, description, context_window,
   input_price_per_million_cents, output_price_per_million_cents,
   supports_tools, is_default_for_provider, deprecated_at)
values
  ('anthropic', 'MiniMax-M3[1m]', 'MiniMax M3 (1M)',
   'MiniMax M3 via API Anthropic-compatible; contexto de 1 milhão de tokens.',
   1000000, 30, 120, true, true, null)
on conflict (provider, model_id) do update set
  display_name = excluded.display_name,
  description = excluded.description,
  context_window = excluded.context_window,
  input_price_per_million_cents = excluded.input_price_per_million_cents,
  output_price_per_million_cents = excluded.output_price_per_million_cents,
  supports_tools = excluded.supports_tools,
  is_default_for_provider = excluded.is_default_for_provider,
  deprecated_at = null;

insert into public.ai_pricing
  (model, prompt_cents_per_million_tokens,
   completion_cents_per_million_tokens, notes)
values
  ('MiniMax-M3[1m]', 30, 120,
   'catálogo 0115 — MiniMax M3 Standard até 512k; preço oficial vigente em 07/08/2026')
on conflict (model) do update set
  prompt_cents_per_million_tokens = excluded.prompt_cents_per_million_tokens,
  completion_cents_per_million_tokens = excluded.completion_cents_per_million_tokens,
  notes = excluded.notes,
  superseded_at = null;

-- Corrige organizações e versões existentes que apontavam para ids Claude,
-- incompatíveis com o endpoint MiniMax configurado nesta distribuição.
update public.organizations
   set settings = jsonb_set(
     coalesce(settings, '{}'::jsonb),
     '{llm}',
     coalesce(settings->'llm', '{}'::jsonb) ||
       jsonb_build_object('provider', 'anthropic', 'default_model', 'MiniMax-M3[1m]'),
     true
   )
 where coalesce(settings->'llm'->>'provider', 'anthropic') = 'anthropic';

update public.ai_agent_versions
   set model = 'MiniMax-M3[1m]'
 where provider = 'anthropic'
   and model <> 'MiniMax-M3[1m]';

notify pgrst, 'reload schema';
