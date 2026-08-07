# Guia Completo de Deploy Universal — DeskcommCRM

> Passo a passo para instalar e colocar o **DeskcommCRM** em produção em **qualquer VPS Linux** (DigitalOcean, Hetzner, Hostinger, AWS, GCP, Contabo, Linode, Vultr ou servidor próprio), do `git clone` até a aplicação rodando com HTTPS, Agentes de IA e WhatsApp.

---

## 📋 1. Pré-Requisitos do Servidor

A instalação é **agnóstica de provedor** e roda em qualquer distribuição Linux baseada em Debian/Ubuntu.

| Requisito | Especificação Recomendada |
|---|---|
| **Servidor VPS** | Ubuntu 22.04 LTS ou 24.04 LTS (mínimo de **4 GB de RAM** e 2 vCPU). |
| **Domínio registrado** | Apontamento de **Registro A** do seu domínio/subdomínio (ex: `crm.suaempresa.com.br`) para o IP público da VPS. |
| **Banco Supabase** | Projeto no [Supabase Cloud](https://supabase.com) (`URL`, `Anon Key`, `Service Role Key` e `SUPABASE_DB_URL`). |
| **Chave de IA** | Chave da **MiniMax AI** ou Anthropic. |
| **Firewall** | Portas **80** (HTTP), **443** (HTTPS) e **22** (SSH) abertas (`ufw allow 80,443,22/tcp`). |

---

## 🚀 2. Passo a Passo do Deploy Genérico

### Passo 1: Conectar na VPS e Instalar o Docker (se necessário)

Acesse seu servidor por SSH. Se o Docker ainda não estiver instalado, instale com o script oficial:

```bash
# 1. Conectar na VPS via SSH
ssh root@seu-ip-vps

# 2. Instalar o Docker + Docker Compose v2 (caso a VPS seja virgem)
curl -fsSL https://get.docker.com | sh

# 3. Habilitar o Docker no boot
systemctl enable --now docker
```

---

### Passo 2: Clonar o Repositório no Servidor

Clone o repositório do projeto para a pasta de sua preferência (ex: `/var/www/crm`):

```bash
# Clonar o repositório
git clone https://github.com/WeslleyMouraDev/LowziCRM.git /var/www/crm

# Entrar no diretório
cd /var/www/crm
```

---

### Passo 3: Configurar as Variáveis de Ambiente (`.env`)

Crie o arquivo `.env` a partir do modelo `.env.example`:

```bash
cp .env.example .env
nano .env
```

Preencha as variáveis de produção no `.env`:

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
# Gere com: openssl rand -hex 32
INTERNAL_SECRET=gerar_hash_hex_com_32_caracteres
SRH_TOKEN=gerar_hash_hex_com_32_caracteres
WAHA_HMAC_SECRET=gerar_hash_hex_com_32_caracteres

# --- WAHA (WHATSAPP) ---
# WAHA_API_KEY_SHA512 deve conter o SHA512 em HEX da senha do WAHA
# Exemplo de geração: echo -n "sua-senha-waha" | sha512sum | awk '{print $1}'
WAHA_API_KEY_SHA512=hash_sha512_da_sua_senha_waha
```

---

### Passo 4: Subir a Aplicação

Escolha a forma que melhor se adapta ao seu ambiente:

#### Opção 1: Script de Instalação Automática
O script de setup aplica as migrations no Supabase, configura os crons e sobe a stack:

```bash
bash hostgator-setup-kit/install.sh
```

#### Opção 2: Docker Compose Direto

- **Cenário A: VPS Limpa (Caddy embutido cuida do HTTPS automático nas portas 80/443)**:
  ```bash
  docker compose -f docker-compose.prod.yml --env-file .env up -d
  ```

- **Cenário B: VPS com Proxy Reverso Existente (Hostinger, Coolify, Dokploy, Traefik, Nginx)**:
  ```bash
  docker compose -f docker-compose.prod.yml -f docker-compose.traefik.yml --env-file .env up -d
  ```

---

## 🔍 3. Diagnóstico Pós-Deploy

Após o deploy, confirme a saúde dos serviços:

### 1. Diagnóstico de Saúde dos Contêineres
```bash
bash hostgator-setup-kit/healthcheck.sh
```

### 2. Teste do Probe HTTP
```bash
curl -s -o /dev/null -w "%{http_code}\n" https://crm.suaempresa.com.br/
```
*(Resposta esperada: `307` ou `200`)*

### 3. Teste da Fila de Automações (`event-log-drain`)
```bash
source .env && curl -s -H "Authorization: Bearer ${INTERNAL_SECRET}" "${NEXT_PUBLIC_APP_URL}/api/v1/cron/event-log-drain"
```

---

## 📱 4. Acesso ao CRM e Conexão do WhatsApp

1. Acesse o domínio no navegador: **`https://crm.suaempresa.com.br`**.
2. Faça login com o usuário criado.
3. Navegue até a seção de **WhatsApp Connections** / **Inbox**.
4. Escaneie o **QR Code** no aplicativo do WhatsApp no celular para conectar o número.
5. A aplicação está pronta para operar com Agentes de IA ativos.

---

## 🛠️ 5. Manutenção e Comandos de Rotina

| Ação | Comando |
|---|---|
| **Atualizar o CRM** | `bash hostgator-setup-kit/update.sh` |
| **Backup Completo** | `bash hostgator-setup-kit/backup.sh` |
| **Restaurar Backup** | `bash hostgator-setup-kit/restore.sh` |
| **Redefinir Senha** | `bash hostgator-setup-kit/reset-password.sh` |
| **Remover MFA de Usuário** | `bash hostgator-setup-kit/reset-mfa.sh` |

---

*Última atualização: 6 de agosto de 2026.*
