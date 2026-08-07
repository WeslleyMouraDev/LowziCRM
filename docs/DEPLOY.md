# Guia Completo de Deploy — DeskcommCRM

> Passo a passo definitivo para instalar e colocar o **DeskcommCRM** em produção na sua própria VPS (self-hosted), desde o clone do repositório no GitHub até a aplicação estar no ar com HTTPS, agentes de IA e WhatsApp conectados.

---

## 📋 1. Pré-Requisitos do Ambiente

Antes de iniciar, garanta que você possui os seguintes itens:

| Requisito | Descrição / Onde Obter |
|---|---|
| **Servidor VPS** | Ubuntu 22.04 LTS ou 24.04 LTS (mínimo de 4 GB de RAM e 2 vCPU recomendados). |
| **Domínio registrado** | Apontamento de **Registro A** do seu domínio ou subdomínio (ex: `crm.suaempresa.com.br`) direcionado para o IP público da sua VPS. |
| **Banco de Dados Supabase** | Projeto criado no [Supabase Cloud](https://supabase.com) (URL do projeto, Anon Key, Service Role Key e Connection String do Postgres `SUPABASE_DB_URL`). |
| **Chave de IA (MiniMax ou Anthropic)** | Chave de API da [MiniMax AI](https://platform.minimax.io) ou Anthropic. |
| **Firewall / Portas** | Portas **80** (HTTP), **443** (HTTPS) e **22** (SSH) abertas no firewall do servidor (`ufw allow 80,443,22/tcp`). |

---

## 🚀 2. Passo a Passo do Deploy

### Passo 1: Conectar na VPS e Clonar o Repositório

Acesse seu servidor VPS via SSH e clone o repositório oficial do GitHub:

```bash
# Conectar na VPS por SSH
ssh root@seu-ip-vps

# Clonar o repositório
git clone https://github.com/WeslleyMouraDev/LowziCRM.git /var/www/crm

# Entrar na pasta do projeto
cd /var/www/crm
```

---

### Passo 2: Configurar as Variáveis de Ambiente (`.env`)

Copie o modelo de arquivo de ambiente `.env.example` para `.env`:

```bash
cp .env.example .env
```

Edite o arquivo `.env` com um editor de texto (ex: `nano .env` ou `vim .env`) e preencha as credenciais essenciais:

```env
# --- DOMÍNIO E REDE ---
DOMAIN=crm.suaempresa.com.br
ACME_EMAIL=seu-email@suaempresa.com.br
NEXT_PUBLIC_APP_URL=https://crm.suaempresa.com.br
NEXT_PUBLIC_ADMIN_URL=https://crm.suaempresa.com.br

# --- SUPABASE (BANCO E AUTH) ---
NEXT_PUBLIC_SUPABASE_URL=https://seu-projeto.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJhbGciOi...
SUPABASE_SERVICE_ROLE_KEY=eyJhbGciOi...
SUPABASE_DB_URL=postgresql://postgres.seu-id:sua-senha@aws-0-sa-east-1.pooler.supabase.com:6543/postgres

# --- INTELIGÊNCIA ARTIFICIAL (MINIMAX AI OU ANTHROPIC) ---
ANTHROPIC_API_KEY=sua_chave_minimax_aqui
ANTHROPIC_BASE_URL=https://api.minimax.io/anthropic

# --- SEGREDOS DE SEGURANÇA E CRONS ---
# Gere strings seguras com: openssl rand -hex 32
INTERNAL_SECRET=gerar_hash_hex_com_32_caracteres
SRH_TOKEN=gerar_hash_hex_com_32_caracteres
WAHA_HMAC_SECRET=gerar_hash_hex_com_32_caracteres

# --- WAHA (WHATSAPP) ---
# WAHA_API_KEY_SHA512 deve conter o SHA512 em HEX da senha plana do WAHA
# Exemplo de geração: echo -n "sua-senha-waha" | sha512sum | awk '{print $1}'
WAHA_API_KEY_SHA512=hash_sha512_da_sua_senha_waha
```

---

### Passo 3: Executar a Instalação

Você pode realizar a instalação de duas formas:

#### Opção A: Instalação Automática Guiada (Recomendada)
O repositório possui um instalador idempotente que verifica o Docker, aplica o schema SQL no Supabase, configura os crons e inicia os contêineres:

```bash
bash hostgator-setup-kit/install.sh
```

> **Se o seu VPS não tiver Docker instalado**, o `install.sh` detecta automaticamente e pergunta se deseja instalar via script oficial do Docker.

#### Opção B: Instalação Manual com Docker Compose v2

Caso prefira subir a stack manualmente via Docker Compose:

1. **VPS Padrão com Caddy (Portas 80/443 livres)**:
   ```bash
   docker compose -f docker-compose.prod.yml --env-file .env up -d
   ```

2. **VPS com Proxy Reverso Próprio (Hostinger, Coolify, Dokploy, Traefik)**:
   ```bash
   docker compose -f docker-compose.prod.yml -f docker-compose.traefik.yml --env-file .env up -d
   ```

---

## 🔍 3. Validação Pós-Deploy & Diagnóstico

Após finalizar o deploy, execute as seguintes verificações para garantir que todos os serviços estão operacionais:

### 1. Diagnóstico Geral de Saúde
Execute o script de diagnóstico do kit:
```bash
bash hostgator-setup-kit/healthcheck.sh
```

### 2. Teste do Probe HTTP
Verifique se a aplicação está respondendo no seu domínio:
```bash
curl -s -o /dev/null -w "%{http_code}\n" https://crm.suaempresa.com.br/
```
*(Resposta esperada: `307` ou `200`)*

### 3. Teste do Fila de Automação (`event-log-drain`)
Dispare um teste manual no cron interno:
```bash
source .env && curl -s -H "Authorization: Bearer ${INTERNAL_SECRET}" "${NEXT_PUBLIC_APP_URL}/api/v1/cron/event-log-drain"
```
*(Resposta esperada: `{"data":{"scanned":...}}`)*

---

## 📱 4. Onboarding Inicial e Conexão do WhatsApp

1. Acesse no navegador o seu domínio: **`https://crm.suaempresa.com.br`**.
2. Faça login com o usuário administrador configurado durante o `install.sh` (ou realize o cadastro da sua primeira organização no Onboarding).
3. Vá para a seção **Inbox / Atendimento** ou **WhatsApp Connections**.
4. Escaneie o **QR Code** exibido na tela usando o seu aplicativo do WhatsApp no celular para parear a sessão.
5. Pronto! Seus Agentes de IA e equipe já podem atender e gerenciar leads no WhatsApp.

---

## 🛠️ 5. Comandos Úteis de Manutenção

O DeskcommCRM traz scripts utilitários em `hostgator-setup-kit/` para facilitar o gerenciamento do seu servidor:

| Comando | Descrição |
|---|---|
| `bash hostgator-setup-kit/update.sh` | Atualiza o sistema para a versão mais recente com backup automático preventivo. |
| `bash hostgator-setup-kit/backup.sh` | Gera backup completo do banco de dados e das sessões do WhatsApp. |
| `bash hostgator-setup-kit/restore.sh` | Restaura um backup previamente criado. |
| `bash hostgator-setup-kit/healthcheck.sh` | Roda diagnóstico dos contêineres e rotas de saúde. |
| `bash hostgator-setup-kit/reset-password.sh` | Redefine a senha de acesso de qualquer usuário. |
| `bash hostgator-setup-kit/reset-mfa.sh` | Remove a autenticação de 2 fatores (MFA) de um usuário travado. |

---

*Última atualização: 6 de agosto de 2026.*
