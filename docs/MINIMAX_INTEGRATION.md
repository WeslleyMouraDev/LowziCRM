# Guia de Integração MiniMax AI no DeskcommCRM

> Instruções de configuração para que o DeskcommCRM utilize a **MiniMax AI** no lugar da Anthropic (Claude) de forma transparente e simplificada, aproveitando a compatibilidade nativa da MiniMax com a **Anthropic-compatible API**.

---

## 1. Visão Geral

A **MiniMax AI** é 100% compatível com a **Anthropic-compatible API** (mesmo protocolo de mensagens, system prompts e *tool calling* do Claude).

No DeskcommCRM, o provedor Anthropic (`anthropic`) em [`lib/agent-engine/edge/llm/providers.ts`](file:///d:/Projetos/LowziCRM/lib/agent-engine/edge/llm/providers.ts) foi configurado para direcionar as requisições nativamente para a URL da MiniMax:

```text
https://api.minimax.io/anthropic
```

Com isso, a aplicação consome os modelos de alta performance da MiniMax sem necessidade de alterar SDKs, refatorar chamadas de agentes ou criar adaptações complexas.

---

## 2. Configuração Simples na Aplicação (`lib/agent-engine/edge/llm/providers.ts`)

A substituição do endpoint da Anthropic pelo da MiniMax ocorre no registro agnóstico de provedores da aplicação:

```typescript
// Em lib/agent-engine/edge/llm/providers.ts

const ANTHROPIC_ENDPOINT = process.env.ANTHROPIC_BASE_URL || 'https://api.minimax.io/anthropic';

export function createDefaultRegistry(opts?: { allowedHosts?: string[] }): ProviderRegistry {
  const extra = opts?.allowedHosts ?? [];
  const contain = (endpoint: string): typeof fetch => {
    const allow = buildAllowlist([endpoint, ...extra]);
    return (input, init) => {
      const url = typeof input === 'string' || input instanceof URL ? input : input.url;
      return allowlistedFetch(url, init, { allowlist: allow });
    };
  };

  return {
    anthropic: (apiKey, modelId) =>
      createAnthropic({ 
        apiKey, 
        baseURL: ANTHROPIC_ENDPOINT, 
        fetch: contain(ANTHROPIC_ENDPOINT) 
      })(modelId),
    openai: (apiKey, modelId) =>
      createOpenAI({ apiKey, fetch: contain(OPENAI_ENDPOINT) })(modelId),
    google: (apiKey, modelId) =>
      createGoogleGenerativeAI({ apiKey, fetch: contain(GOOGLE_ENDPOINT) })(modelId),
  };
}
```

---

## 3. Como Chaves e Variáveis de Ambiente são Lidas

1. **Variável de Ambiente (`.env`)**:
   Defina sua chave de API da MiniMax na variável padrão de API key do provedor:
   ```env
   ANTHROPIC_API_KEY="sua_chave_minimax_aqui"
   ```
   Caso deseje sobrescrever a URL padrão em algum ambiente específico (por exemplo, na China), configure:
   ```env
   ANTHROPIC_BASE_URL="https://api.minimaxi.com/anthropic"
   ```

2. **BYOK (Bring Your Own Key) por Organização**:
   Cada organização/tenant pode cadastrar sua chave da MiniMax diretamente no painel ou na tabela `ai_provider_credentials` sob o provedor `'anthropic'`. O CRM utilizará a URL `https://api.minimax.io/anthropic` automaticamente.

---

## 4. Modelos da MiniMax Utilizados pelos Agentes

Os Agentes de IA do CRM (atendimento por WhatsApp, RAG por tenant, classificação de leads) continuam utilizando a estrutura do `Agent Engine`, bastando definir o modelo desejado (ex: `minimax-text-01` ou modelos M-series equivalentes).

---

## 5. Checklist de Validação da Aplicação

- [ ] **Provedor Ativo**: A variável `ANTHROPIC_API_KEY` (com a chave da MiniMax) está configurada no `.env` ou cadastrada no tenant.
- [ ] **Egress Liberado**: O `allowlistedFetch` autoriza a chamada para `https://api.minimax.io/anthropic`.
- [ ] **Testes de Integração**: Executar `pnpm test:unit` para garantir a estabilidade dos registries e handlers do CRM.

---

*Última atualização: 6 de agosto de 2026.*
