# Auto-instalador do LowziCRM

O fluxo oficial usa imagens prontas do GitHub Container Registry. A VPS ou o Mac não precisa instalar Node.js, pnpm ou compilar o Next.js.

## O que você precisa

### Em qualquer instalação

1. **Docker + Docker Compose v2** — o instalador oferece instalar no Linux; no macOS usa Docker Desktop.
2. **Projeto Supabase** com:
   - Project URL;
   - anon/publishable key;
   - service role/secret key;
   - Database URI do pooler IPv4.
3. **Chave da MiniMax API**.
4. E-mail, senha e nome da empresa do primeiro administrador.

### Para publicar numa VPS

- VPS Linux com pelo menos 4 GB de RAM recomendados;
- domínio com registro A apontando para o IPv4 da VPS;
- portas 80 e 443 liberadas;
- e-mail para emissão do certificado TLS.

No macOS, o modo suportado pelo instalador é local em `http://localhost:3000`. Para produção 24/7, use uma VPS Linux.

## Instalação

### Clone explícito

```bash
git clone https://github.com/WeslleyMouraDev/LowziCRM.git
cd LowziCRM
./install.sh
```

### Um comando

```bash
curl -fsSL https://raw.githubusercontent.com/WeslleyMouraDev/LowziCRM/main/install.sh -o /tmp/lowzicrm-install.sh && bash /tmp/lowzicrm-install.sh
```

O modo padrão é:

- `public` em Linux;
- `local` em macOS.

Para escolher:

```bash
./install.sh --mode local
./install.sh --mode public
```

## O que o instalador faz

1. Detecta Linux/macOS e arquitetura da CPU.
2. Verifica Docker e Compose.
3. Entrevista o usuário sem mostrar chaves ou senhas.
4. Gera os segredos internos com OpenSSL.
5. Salva `.env` com permissão `600`.
6. Escolhe o WAHA oficial ou a imagem sem SIMD para CPUs x86 antigas.
7. Valida o PostgreSQL e aplica o baseline em banco vazio.
8. Baixa imagens prontas do app, worker e WAHA.
9. Inicia a stack.
10. Cria o primeiro administrador de forma idempotente.
11. Aguarda o health check real.

Dados já existentes não são apagados. Atualizações reaplicam o apêndice idempotente do baseline e preservam o banco e os volumes.

## Operação diária

Após a instalação:

```bash
./lowzicrm status
./lowzicrm logs
./lowzicrm doctor
./lowzicrm update
./lowzicrm stop
./lowzicrm start
./lowzicrm uninstall              # preserva volumes
./lowzicrm uninstall --purge-data # remoção definitiva após confirmação
```

`uninstall` nunca apaga o projeto Supabase externo. Volumes locais só são apagados quando `--purge-data` é informado explicitamente.

## Instalação não interativa

Preencha o `.env` com as variáveis da stack. Passe as credenciais de bootstrap
somente no ambiente do processo (elas não ficam persistidas no `.env`):

```bash
OWNER_EMAIL='dono@empresa.com' \
OWNER_PASSWORD='uma-senha-forte' \
OWNER_ORG_NAME='Minha empresa' \
./install.sh --yes --mode public
```

O modo `--yes` falha de forma fechada se faltar algum campo obrigatório; não inventa credenciais externas.

## Imagens publicadas

O workflow `.github/workflows/publish-image.yml` publica:

- `ghcr.io/weslleymouradev/lowzicrm:latest` — aplicação Next.js;
- `ghcr.io/weslleymouradev/lowzicrm-worker:latest` — worker 24/7;
- `ghcr.io/weslleymouradev/lowzicrm-waha:2026.6.2-compat` — WAHA x86 sem dependência de SIMD moderna.

App e worker são publicados para `linux/amd64` e `linux/arm64`. A variante WAHA de CPU antiga é exclusiva para `linux/amd64`.

## Limites atuais

- O modo público embutido usa Caddy e exige as portas 80/443 livres.
- Cloudflare Tunnel, Traefik, Coolify e Dokploy continuam sendo cenários avançados com overrides próprios.
- O Supabase permanece um serviço externo; o instalador não cria o projeto na conta do usuário.
