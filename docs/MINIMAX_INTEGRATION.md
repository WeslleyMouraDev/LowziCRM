# Guia de Integração MiniMax AI no DeskcommCRM

> Instruções completas para integração e configuração do provedor de LLM **MiniMax AI** nos Agentes de IA do **DeskcommCRM**, cobrindo gestão de credenciais BYOK, arquitetura do Agent Engine (`lib/agent-engine/`) e contenção de egress.

---

## 1. Visão Geral

A **MiniMax AI** é um provedor de Inteligência Artificial de alta performance que oferece modelos LLM eficientes (linha **M-series**, como `minimax-text-01`). No DeskcommCRM, a MiniMax serve como engine de inteligência para a camada de Agentes de IA responsáveis por atendimento automatizado via WhatsApp, triagem e RAG (Retrieval-Augmented Generation) por tenant, além de classificação de leads.

Uma das principais vantagens da plataforma MiniMax é a sua **arquitetura de compatibilidade dual**:

- **Anthropic-compatible API** (`https://api.minimax.io/anthropic`): Permite instanciar o provedor utilizando o pacote `@ai-sdk/anthropic`, mantendo a mesma estrutura de mensagens, system prompts e suporte a chamadas de ferramentas (*tool calling*).
- **OpenAI-compatible API** (`https://api.minimax.io/v1`): Permite integração utilizando o pacote `@ai-sdk/openai`, facilitando a interoperabilidade e substituição transparente com APIs baseadas no padrão OpenAI.

---

## 2. Gestão de Credenciais no DeskcommCRM

O DeskcommCRM adota uma arquitetura de segurança multi-tenant baseada em isolamento de credenciais, oferecendo suporte tanto a chaves globais da plataforma quanto a credenciais próprias de cada organização (BYOK).

### Variável de Ambiente (`.env`)

Para fornecer uma chave de fallback no nível da plataforma (utilizada quando uma organização não possui chave BYOK cadastrada ou em rotinas do sistema), configure a seguinte variável no arquivo `.env`:

```env
MINIMAX_API_KEY="sua_chave_minimax_aqui"
```

> **Nota**: Lembre-se de registrar a variável em `.env.example` e na validação centralizada de variáveis em `lib/env.ts`.

### BYOK (Bring Your Own Key) por Organização

Para garantir o isolamento total de custos e limites por tenant, cada organização pode cadastrar sua própria chave da MiniMax na tabela `ai_provider_credentials`.

- **Tabela**: `ai_provider_credentials`
- **Campos**: `organization_id`, `provider` (`'minimax'`), `api_key_hash` / segredo criptografado.
- **Funcionamento**: A cada execução do Agent Engine, a chave da MiniMax correspondente ao `organization_id` autenticado é recuperada de forma segura para instanciar o provedor sob demanda (sem pool global compartilhado).

---

## 3. Arquitetura do Agent Engine (`lib/agent-engine/`)

A camada de inteligência do DeskcommCRM (`lib/agent-engine/edge/llm/providers.ts`) é agnóstica de fornecedor e utiliza os SDKs da Vercel AI SDK (`@ai-sdk/anthropic` e `@ai-sdk/openai`).

### Registro do Provedor em `lib/agent-engine/edge/llm/providers.ts`

#### Exemplo em TypeScript usando `@ai-sdk/anthropic`

```typescript
import { createAnthropic } from '@ai-sdk/anthropic';

const minimaxAnthropic = createAnthropic({
  baseURL: 'https://api.minimax.io/anthropic',
  apiKey: apiKey,
});

// Instanciando o modelo MiniMax M-series
const model = minimaxAnthropic('minimax-text-01');
```

#### Exemplo em TypeScript usando `@ai-sdk/openai`

```typescript
import { createOpenAI } from '@ai-sdk/openai';

const minimaxOpenAI = createOpenAI({
  baseURL: 'https://api.minimax.io/v1',
  apiKey: apiKey,
});

// Instanciando o modelo MiniMax via camada compatível com OpenAI
const model = minimaxOpenAI('minimax-text-01');
```

### Contenção de Egress (Egress Security Allowlist)

O DeskcommCRM possui uma camada estrita de contenção de tráfego de saída (*Egress Security*). Por padrão, todas as requisições HTTP feitas pelos SDKs de LLM são interceptadas e validadas por uma allowlist via `allowlistedFetch`.

Para autorizar o tráfego de saída destinado aos servidores da MiniMax, adicione os endpoints `https://api.minimax.io` e `https://api.minimaxi.com` (endpoint da região Ásia-Pacífico/China) à allowlist do `allowlistedFetch` em `lib/agent-engine/edge/llm/providers.ts`:

```typescript
// Em lib/agent-engine/edge/llm/providers.ts

const MINIMAX_ENDPOINT = 'https://api.minimax.io';
const MINIMAX_CHINA_ENDPOINT = 'https://api.minimaxi.com';

export function createDefaultRegistry(opts?: { allowedHosts?: string[] }): ProviderRegistry {
  const extra = opts?.allowedHosts ?? [];

  const contain = (endpoint: string): typeof fetch => {
    const allow = buildAllowlist([endpoint, MINIMAX_ENDPOINT, MINIMAX_CHINA_ENDPOINT, ...extra]);
    return (input, init) => {
      const url = typeof input === 'string' || input instanceof URL ? input : input.url;
      return allowlistedFetch(url, init, { allowlist: allow });
    };
  };

  return {
    anthropic: (apiKey, modelId) =>
      createAnthropic({ apiKey, fetch: contain(ANTHROPIC_ENDPOINT) })(modelId),
    openai: (apiKey, modelId) =>
      createOpenAI({ apiKey, fetch: contain(OPENAI_ENDPOINT) })(modelId),
    google: (apiKey, modelId) =>
      createGoogleGenerativeAI({ apiKey, fetch: contain(GOOGLE_ENDPOINT) })(modelId),
    minimax: (apiKey, modelId) =>
      createAnthropic({
        apiKey,
        baseURL: 'https://api.minimax.io/anthropic',
        fetch: contain(MINIMAX_ENDPOINT),
      })(modelId),
  };
}
```

---

## 4. Atribuição de Modelos MiniMax aos Agentes de IA

Cada agente de IA (atendimento via WhatsApp, assistente de RAG ou classificador de leads) possui sua configuração armazenada no banco de dados e associada ao tenant (`organization_id`).

1. **Mapeamento de Modelos**:
   - Modelos recomendados: `minimax-text-01` e variantes M-series da MiniMax.
2. **Configuração do Agente**:
   - No perfil do agente (`ai_agents` ou tabela de configuração do tenant), especifique o provedor como `minimax` e o modelo como `minimax-text-01`.
3. **Resolução em Tempo de Execução**:
   - Quando uma nova conversa ou mensagem do WhatsApp é recebida pelo webhook WAHA, o dispatcher do Agent Engine recupera as credenciais BYOK da org, consulta o `ProviderRegistry` para o provedor `minimax`, e executa `generateText` ou `streamText` de forma isolada e segura.

---

## 5. Checklist de Validação no CRM

Após realizar a configuração ou atualização do provedor MiniMax no DeskcommCRM, execute o checklist de validação:

### 1. Testes Unitários dos Providers

Valide se o registro do provedor e a suíte de testes de unidade estão funcionando corretamente:

```bash
pnpm test:unit
```

### 2. Logs Estruturados (`lib/logger.ts`)

Verifique os logs gerados pelo sistema em tempo de execução usando o logger estruturado da aplicação (`lib/logger.ts`). Certifique-se de que:
- O tráfego para a MiniMax não está sendo bloqueado pelo controle de egress (ausência de `EgressBlockedError`).
- Nenhuma chave de API ou dado sensível (PII) é registrado nos logs.

Exemplo de log estruturado esperado no atendimento:

```json
{
  "level": "info",
  "message": "Agente executado com sucesso via MiniMax",
  "provider": "minimax",
  "model": "minimax-text-01",
  "organizationId": "org_123..."
}
```

### 3. Governança e Tipagem

Certifique-se de que a verificação estática de tipos e o linter passem sem erros:

```bash
pnpm gov:verify
```
