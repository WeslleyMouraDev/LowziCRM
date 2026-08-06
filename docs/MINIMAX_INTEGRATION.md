# Guia de Integração MiniMax AI para Vibe Coding e CRM Runtime

> Como configurar os modelos de alta performance da MiniMax AI tanto no seu ambiente local de **Vibe Coding** (Claude Code, AGY, Cursor) quanto no **Runtime de Agentes do DeskcommCRM** (`lib/agent-engine/`).

---

## 1. Visão Geral

A **MiniMax AI** oferece uma família de LLMs de altíssima velocidade e eficiência de custo/desempenho (modelos **M-series**, como `minimax-text-01` e variantes M-series). 

Uma das principais vantagens da plataforma MiniMax é a sua **arquitetura de compatibilidade dual**:
- **Compatibilidade Anthropic API**: Permite apontar ferramentas como Claude Code e a biblioteca `@ai-sdk/anthropic` diretamente para o endpoint Anthropic-compatible da MiniMax, mantendo o formato de mensagens, system prompts e tool calling.
- **Compatibilidade OpenAI API**: Permite consumo direto usando a estrutura OpenAI v1 (`@ai-sdk/openai`), facilitando a substituição transparente ou fallback de modelos.

No DeskcommCRM, a MiniMax pode ser utilizada tanto como o **engine de inteligência para o desenvolvedor (Vibe Coding)** quanto como **provedor de LLM para os Agentes de IA do CRM** em produção.

---

## 2. Configurando MiniMax para Ferramentas de Vibe Coding (Claude Code, AGY, Cursor)

Para utilizar a MiniMax AI como backend LLM em ferramentas como **Claude Code**, **AGY (Antigravity CLI)** ou **Cursor**, siga o passo a passo abaixo.

### Passo 1: Limpeza de Variáveis Conflitantes
Se você utilizou anteriormente tokens do Claude ou rotas legadas, limpe as variáveis no terminal para evitar conflitos de autenticação:

```bash
unset ANTHROPIC_AUTH_TOKEN
unset ANTHROPIC_BASE_URL
```

> **Nota**: O uso de `ANTHROPIC_AUTH_TOKEN` pode se sobrepor à `ANTHROPIC_API_KEY`. Certifique-se de removê-lo antes de aplicar a chave da MiniMax.

### Passo 2: Configuração no `~/.claude/settings.json`
Edite ou crie o arquivo de configurações do Claude Code (`~/.claude/settings.json`) incluindo o bloco `"env"` com o endpoint da MiniMax:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://api.minimax.io/anthropic",
    "ANTHROPIC_API_KEY": "<SUA_MINIMAX_API_KEY>"
  }
}
```

> **Atenção (Usuários na China / Região Ásia-Pacífico)**: Se estiver operando em infraestrutura na China Continental, utilize o endpoint local:
> ```json
> "ANTHROPIC_BASE_URL": "https://api.minimaxi.com/anthropic"
> ```

### Passo 3: Uso via Variáveis de Ambiente Globais
Para persistir a configuração no seu terminal (Bash ou Zsh), adicione as exportações ao seu `~/.bashrc` ou `~/.zshrc`:

```bash
# Adicione ao ~/.bashrc ou ~/.zshrc
export ANTHROPIC_BASE_URL="https://api.minimax.io/anthropic"
export ANTHROPIC_API_KEY="<SUA_MINIMAX_API_KEY>"
```

Carregue a nova configuração com `source ~/.bashrc` (ou `source ~/.zshrc`).

---

## 3. Configurando MiniMax no Runtime do DeskcommCRM (`lib/agent-engine/`)

No DeskcommCRM, a camada agnóstica de LLMs (`lib/agent-engine/edge/llm/providers.ts`) faz a ponte entre os agentes e as APIs de inteligência usando a Vercel AI SDK.

### Exemplo em TypeScript usando `@ai-sdk/anthropic`
Graças ao endpoint Anthropic-compatible da MiniMax, você pode instanciar o provedor utilizando `@ai-sdk/anthropic`:

```typescript
import { createAnthropic } from '@ai-sdk/anthropic';

const minimaxAnthropic = createAnthropic({
  baseURL: 'https://api.minimax.io/anthropic',
  apiKey: process.env.MINIMAX_API_KEY,
});

// Instanciando o modelo MiniMax M-series
const model = minimaxAnthropic('minimax-text-01');
```

### Exemplo em TypeScript usando `@ai-sdk/openai`
Se optar pela interface compatível com OpenAI API:

```typescript
import { createOpenAI } from '@ai-sdk/openai';

const minimaxOpenAI = createOpenAI({
  baseURL: 'https://api.minimax.io/v1',
  apiKey: process.env.MINIMAX_API_KEY,
});

// Instanciando o modelo MiniMax via OpenAI compatibility layer
const model = minimaxOpenAI('minimax-text-01');
```

### Atualização na Egress Allowlist (`lib/agent-engine/edge/llm/providers.ts`)
O DeskcommCRM possui uma camada estrita de contenção de tráfego de saída (Egress Security). Por padrão, todo `fetch` feito pelos provedores de LLM é filtrado por uma allowlist.

Para autorizar as chamadas HTTP para os servidores da MiniMax, adicione os endpoints `https://api.minimax.io` e `https://api.minimaxi.com` às constantes de endpoints ou ao parâmetro `allowedHosts` ao criar o registry:

```typescript
// Em lib/agent-engine/edge/llm/providers.ts

const MINIMAX_ENDPOINT = 'https://api.minimax.io';
const MINIMAX_CHINA_ENDPOINT = 'https://api.minimaxi.com';

export function createDefaultRegistry(opts?: { allowedHosts?: string[] }): ProviderRegistry {
  const extra = opts?.allowedHosts ?? [];
  
  // Inclui os hosts da MiniMax na allowlist de egress seguro
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

## 4. Prompts Prontos para Vibe Coding

Utilize estes prompts prontos ao interagir com seu assistente de Vibe Coding (Claude Code, AGY ou Cursor):

### Prompt A: Configurar Claude Code / AGY para usar MiniMax API Key
```text
Preciso configurar a MiniMax AI como meu provedor padrão para o Claude Code / AGY neste ambiente.
Por favor, verifique se a variável ANTHROPIC_AUTH_TOKEN está nula e configure as variáveis no ~/.claude/settings.json com a ANTHROPIC_BASE_URL="https://api.minimax.io/anthropic" e a minha chave em ANTHROPIC_API_KEY.
```

### Prompt B: Adicionar MiniMax como Provedor Adicional no Runtime do DeskcommCRM (`providers.ts`)
```text
Adicione o provedor 'minimax' ao ProviderRegistry em `lib/agent-engine/edge/llm/providers.ts` no DeskcommCRM.
Garantias obrigatórias:
1. Use `@ai-sdk/anthropic` configurado com a baseURL `https://api.minimax.io/anthropic`.
2. Garanta que o `fetch` passe pela contenção de egress `contain(MINIMAX_ENDPOINT)`.
3. Adicione `https://api.minimax.io` e `https://api.minimaxi.com` na allowlist de egress seguro.
4. Mantenha os tipos estritos em TypeScript e garanta que `pnpm typecheck` passe zerado.
```

### Prompt C: Trocar o Modelo Padrão do Agente para MiniMax M-series
```text
Configure o modelo padrão do Agente de Atendimento no DeskcommCRM para utilizar o modelo MiniMax M-series (`minimax-text-01`).
Certifique-se de passar a chave `MINIMAX_API_KEY` do ambiente, validar a chamada via Zod e garantir isolamento por `organization_id`.
```

---

## 5. Checklist de Validação & Diagnóstico

Após realizar a integração da MiniMax AI, siga o checklist abaixo para confirmar o funcionamento:

### 1. Teste de Chamada via cURL (Endpoint Anthropic-compatible)
Valide a conectividade da chave de API e do endpoint executando no terminal:

```bash
curl -X POST https://api.minimax.io/anthropic/v1/messages \
  -H "x-api-key: $MINIMAX_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{
    "model": "minimax-text-01",
    "max_tokens": 100,
    "messages": [{"role": "user", "content": "Olá, MiniMax!"}]
  }'
```

### 2. Verificação de Logs de Egress
Certifique-se de que os logs de saída não indicam bloqueio de segurança (`EgressBlockedError`).
Se o tráfego for bloqueado, confirme se o domínio `api.minimax.io` foi corretamente adicionado à allowlist em `lib/agent-engine/edge/llm/providers.ts` ou `lib/agent-engine/edge/egress.ts`.

### 3. Validação da Suíte de Testes
Execute a verificação estática e unitária do repositório para garantir que a integração e as alterações no registry de provedores não quebraram contratos existentes:

```bash
pnpm gov:verify
```

---
