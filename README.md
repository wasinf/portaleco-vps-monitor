# PortalEco VPS Monitor

Monitoramento da infraestrutura da VPS do Portal Eco.

## Estrutura

- backend → API Node.js
- frontend → Interface web
- infra → Docker Compose e orquestração

## Produção

Rodando via:
- Docker
- Nginx Proxy Manager
- Cloudflare Tunnel

## Portas internas

Backend → 4000  
Frontend → 4001

## Staging (portas internas)

Backend staging → 4100  
Frontend staging → 4101

## Estabilidade de proxy (anti-502)

No `docker-compose` do monitor, os serviços usam IP fixo na rede `npm-network`:

- Produção: backend `172.20.0.30`, frontend `172.20.0.31`
- Staging: backend `172.20.0.40`, frontend `172.20.0.41`

Isso reduz risco de `502` no Nginx Proxy Manager após redeploy por troca de IP dinâmico.

## Autenticação do dashboard

As rotas `/api/*` são protegidas por token Bearer (exceto `/api/auth/login`).
Usuários são persistidos em banco SQLite no backend (`AUTH_DB_PATH`, padrão `/data/auth.db`).
Na primeira inicialização, o usuário admin é criado a partir de `AUTH_USERNAME` e `AUTH_PASSWORD`.

Configuração recomendada:

1. Copiar `infra/.env.example` para `infra/.env`
2. Alterar `AUTH_USERNAME`, `AUTH_PASSWORD`, `AUTH_TOKEN_SECRET`
3. Subir/rebuildar com Docker Compose

Exemplo (produção):

```bash
cd /opt/apps/portaleco-vps-monitor/infra
cp .env.example .env
docker compose up -d --build
```

Exemplo (staging):

```bash
cd /opt/apps/portaleco-vps-monitor/infra
cp .env.staging.example .env.staging
docker compose --env-file .env.staging -f docker-compose.staging.yml up -d --build
```

## Deploy por ambiente

Script em `deploy.sh` com suporte a:

- `./deploy.sh prod`
- `./deploy.sh staging`

O script faz smoke test automatico apos subir:

- loopback dentro do container backend: `GET /health`
- loopback dentro do container frontend: `GET /`
- smoke publico opcional (dominio de `ALLOWED_ORIGINS` ou `RELEASE_SMOKE_ORIGIN`)
- Precheck de ambiente (`scripts/deploy_precheck.sh`)

Se algum teste falhar, o deploy termina com erro.

Para ignorar o precheck (apenas em emergencia):

```bash
RUN_DEPLOY_PRECHECK=false ./deploy.sh prod
```

Para ignorar smoke pos-deploy (apenas em emergencia):

```bash
RUN_RELEASE_SMOKE=false ./deploy.sh prod
```

## Endpoints de autenticação

- `POST /api/auth/login`
- `POST /api/auth/logout`
- `GET /api/auth/me`
- `POST /api/auth/change-password`
- `GET /api/auth/users` (admin)
- `POST /api/auth/users` (admin)
- `PATCH /api/auth/users/:username/active` (admin)

Sessao web:

- login grava cookie `HttpOnly` (sem uso de token em `localStorage`)
- frontend envia credenciais por cookie com `credentials: include`

## Observabilidade

Backend gera logs estruturados em JSON por requisicao com:

- `request_id` (tambem enviado no header `x-request-id`)
- metodo, path, status, latencia (`latency_ms`)
- IP de origem e usuario autenticado (quando existir)

Para silenciar logs HTTP: `LOG_LEVEL=silent`.

## Backup de autenticacao

Scripts adicionados em `scripts/` para backup/restore dos volumes SQLite de auth:

- `./scripts/backup_create.sh`
- `./scripts/backup_restore.sh [prod|staging] /caminho/auth-<env>-<timestamp>.tgz`

Detalhes:

- backups sao salvos em `backups/` (ou `BACKUP_DIR` customizado)
- hash `sha256` e gerado por arquivo
- limpeza automatica por retencao com `RETENTION_DAYS` (padrao: 14)

Exemplo:

```bash
cd /opt/apps/portaleco-vps-monitor
./scripts/backup_create.sh
```

## Healthcheck com alerta opcional

Script: `./scripts/health_alert_check.sh`

Ele valida `running/healthy` para:

- `portaleco-vps-monitor-backend`
- `portaleco-vps-monitor-frontend`
- `portaleco-vps-monitor-backend-staging`
- `portaleco-vps-monitor-frontend-staging`

Se houver falha, retorna `exit 1` e opcionalmente envia webhook via:

- `ALERT_WEBHOOK_URL`
- arquivo local `infra/.health-alert.env` (nao versionado)

Exemplo:

```bash
cd /opt/apps/portaleco-vps-monitor
cp infra/.health-alert.env.example infra/.health-alert.env
# editar ALERT_WEBHOOK_URL no arquivo
./scripts/health_alert_check.sh
```

## Crontab recomendado

Exemplo simples (backup diario + healthcheck a cada 5 min):

```cron
0 2 * * * cd /opt/apps/portaleco-vps-monitor && ./scripts/backup_create.sh >/var/log/portaleco-backup.log 2>&1
*/5 * * * * cd /opt/apps/portaleco-vps-monitor && ./scripts/health_alert_check.sh >/var/log/portaleco-health.log 2>&1
```

## Preflight de release

Script: `./scripts/release_preflight.sh`

Valida automaticamente:

- variaveis criticas em `infra/.env` e `infra/.env.staging`
- containers `running/healthy` em prod e staging
- presenca das entradas de cron esperadas
- existencia de backup recente em `backups/`

Exemplo:

```bash
cd /opt/apps/portaleco-vps-monitor
./scripts/release_preflight.sh
```

## Precheck de deploy

Script: `./scripts/deploy_precheck.sh [prod|staging]`

Valida por ambiente:

- arquivo `.env` correspondente
- `AUTH_FAIL_ON_INSECURE_DEFAULTS=true`
- `ALLOWED_ORIGINS` com `https://`
- `AUTH_TOKEN_SECRET` e `AUTH_PASSWORD` fora de default e com tamanho minimo
- `docker compose config` valido

## Rotacao de credenciais auth

Script: `./scripts/rotate_auth_secrets.sh [prod|staging|both] [--apply]`

Comportamento:

- sem `--apply`: apenas `dry-run` (gera valores e mostra mascarado)
- com `--apply`: atualiza `.env`, faz deploy do ambiente e aplica troca efetiva de senha via API

Exemplos:

```bash
cd /opt/apps/portaleco-vps-monitor
./scripts/rotate_auth_secrets.sh both
./scripts/rotate_auth_secrets.sh prod --apply
```

## Sincronizacao de senha com .env

Script: `./scripts/auth_sync_from_env.sh [prod|staging]`

Uso recomendado quando houver divergencia entre senha do `.env` e senha persistida no SQLite.

Comportamento:

- se a senha do `.env` ja estiver valida no banco: nao altera nada
- se houver divergencia: atualiza apenas o hash da senha do usuario `AUTH_USERNAME`

Exemplos:

```bash
cd /opt/apps/portaleco-vps-monitor
./scripts/auth_sync_from_env.sh prod
./scripts/auth_sync_from_env.sh staging
```

## Padrao de commit PT-BR

Template de commit disponivel em:

- `.gitmessage-ptbr.txt`

Aplicar no repositorio local:

```bash
cd /opt/apps/portaleco-vps-monitor
./scripts/git_setup_ptbr.sh
```

Depois disso, ao usar `git commit` sem `-m`, o editor abre com o template PT-BR.

## Fluxo Git automatico

Comando unico para criar/entrar na branch e subir implementacao:

```bash
BRANCH="<tipo>/<descricao-curta>"; git rev-parse --verify "$BRANCH" >/dev/null 2>&1 && git checkout "$BRANCH" || git checkout -b "$BRANCH"; npm run git:auto
```

Padrao de branch:

- `fix/...` para correcao
- `feat/...` para funcionalidade nova
- `chore/...` para manutencao

Observacoes:

- `npm run git:auto` usa `scripts/git_auto.sh`
- o script faz `git add -A`, gera commit em PT-BR com base no nome da branch e faz push
- para customizar descricao do commit: `GIT_AUTO_DESC="sua descricao" npm run git:auto`
