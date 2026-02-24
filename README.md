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

## Discos do host no card Sistema

O backend monta o host em `/hostfs` (somente leitura) para listar volumes/discos reais do servidor no campo `Volumes`.
Se necessario, ajustar `HOST_FS_ROOT` no `.env` (padrao: `/hostfs`).

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
- `./deploy.sh prod main` (branch/tag opcional; padrao: `main`)

O script faz smoke test automatico apos subir:

- loopback dentro do container backend: `GET /health`
- loopback dentro do container frontend: `GET /`
- smoke publico opcional (dominio de `ALLOWED_ORIGINS` ou `RELEASE_SMOKE_ORIGIN`)
- Precheck de ambiente (`scripts/deploy_precheck.sh`)
- Rollout sequencial (menor downtime): `build` antecipado, atualiza backend e frontend em etapas (`--no-deps`) com espera de saude entre elas

Tambem grava log completo por execucao em:

- `logs/deploy_YYYYmmdd_HHMMSS.log`

Se algum teste falhar, o deploy termina com erro.

Para ignorar o precheck (apenas em emergencia):

```bash
RUN_DEPLOY_PRECHECK=false ./deploy.sh prod
```

Para ignorar smoke pos-deploy (apenas em emergencia):

```bash
RUN_RELEASE_SMOKE=false ./deploy.sh prod
```

Para ignorar preflight pos-deploy (apenas em emergencia):

```bash
RUN_POST_DEPLOY_PREFLIGHT=false ./deploy.sh prod
```

Para exigir checks de superficie administrativa na publicacao:

```bash
DEPLOY_STRICT_ADMIN_SURFACE=true ./deploy.sh prod
```

Esse modo repassa:

- `SECURITY_STRICT_ADMIN_SURFACE=true`
- `HOST_SURFACE_STRICT_ADMIN=true`

Importante: com `ADMIN_ACCESS_MODE=lan_whitelist`, bind publico administrativo e aceito nos checks
desde que o controle de acesso esteja no firewall (`DOCKER-USER`/UFW) com whitelist de LAN.
Com `ADMIN_ACCESS_MODE=tunnel_only`, o modo estrito bloqueia bind publico administrativo.

Para manter o deploy operacional quando houver falha temporaria de DNS/GitHub no host:

```bash
DEPLOY_SKIP_GIT_UPDATE=true ./deploy.sh prod
```

Esse modo:

- nao executa `git fetch/checkout/pull` no inicio do deploy
- usa exatamente o codigo ja presente no disco
- e recomendado apenas para contingencia (curto prazo)

## Runbook de operacao (producao)

Fluxo recomendado de publicacao:

1. Deploy normal (padrao)
2. Contingencia sem update Git (somente quando necessario)
3. Rollback por ref (tag/commit) quando houver regressao

### 1) Deploy normal (padrao)

```bash
cd /opt/apps/portaleco-vps-monitor
DEPLOY_STRICT_ADMIN_SURFACE=true ./deploy.sh prod main
```

Esperado:

- `Deploy finalizado com sucesso!`
- preflight final com `Erros: 0`

### 2) Contingencia (GitHub/DNS instavel)

Use apenas quando `git fetch/pull` falhar por conectividade e o codigo local ja estiver validado.

```bash
cd /opt/apps/portaleco-vps-monitor
DEPLOY_STRICT_ADMIN_SURFACE=true DEPLOY_SKIP_GIT_UPDATE=true ./deploy.sh prod main
```

### 3) Rollback rapido por tag/branch

Se houver regressao apos deploy:

```bash
cd /opt/apps/portaleco-vps-monitor
DEPLOY_STRICT_ADMIN_SURFACE=true ./deploy.sh prod <tag-ou-branch-anterior>
```

Exemplo:

```bash
DEPLOY_STRICT_ADMIN_SURFACE=true ./deploy.sh prod v1.1.0
```

### 4) Verificacao pos-deploy (manual)

```bash
cd /opt/apps/portaleco-vps-monitor
./scripts/release_preflight.sh prod
curl -I https://monitor.portalecomdo.com.br
```

Criticos:

- backend/frontend `running=true` e `health=healthy`
- auth login probe interno/publico `OK`
- `Erros: 0` no preflight

## Politica de acesso administrativo (padrao unico)

Padrao recomendado e adotado: **opcao B (LAN + whitelist)**.

- `ADMIN_ACCESS_MODE=lan_whitelist`
- Portainer em bind LAN (`0.0.0.0:9443`)
- Bloqueio/restricao no firewall (`DOCKER-USER`) por CIDR autorizado
- Sem misturar com `tunnel_only` sem documentacao formal

Arquivo versionado de politica:

- `infra/admin-surface.env.example`

Para ativar no host:

```bash
cd /opt/apps/portaleco-vps-monitor/infra
cp admin-surface.env.example admin-surface.env
```

## Lockdown de superficie administrativa (8088/9443)

Script: `./scripts/admin_surface_lockdown.sh [--check|--apply|--remove]`

- `--check`: valida regras conforme `ADMIN_ACCESS_MODE`
- `--apply`: aplica regras no `DOCKER-USER`
- `--remove`: remove regras gerenciadas pelo script

Padrao de portas monitoradas:

- `8088,9443`

No modo `lan_whitelist`, o script aplica:

- `ACCEPT` por CIDR da whitelist para as portas admin
- `REJECT` para demais origens nas mesmas portas

Exemplos:

```bash
cd /opt/apps/portaleco-vps-monitor
sudo ./scripts/admin_surface_lockdown.sh --check
sudo ./scripts/admin_surface_lockdown.sh --apply
sudo ./scripts/admin_surface_lockdown.sh --remove
```

Atalhos npm:

```bash
npm run admin:surface:check
npm run admin:surface:apply
```

## Hardening recente (deploy/auth)

Melhorias aplicadas para reduzir falhas por contexto de execucao, inconsistencias de ambiente e risco de deploy inseguro:

1. Validacao fail-fast de rede externa `npm-network` no `deploy.sh`

- Antes do `docker compose up`, o script verifica se a rede externa existe.
- Se nao existir, o deploy aborta com mensagem objetiva de correcao.

2. Correcao de path absoluto no `scripts/auth_login_probe.sh`

- O probe agora resolve `.env` com base no diretorio raiz do projeto (`ROOT_DIR`), evitando erro por caminho relativo quando chamado por outros scripts.
- Arquivos usados:
  - `infra/.env`
  - `infra/.env.staging`

3. Protecao de producao quando `infra/.env` estiver ausente

- Em `prod`, se `.env` nao existir:
  - cria a partir de `.env.example`
  - aborta o deploy na sequencia
  - orienta revisao de credenciais antes de nova execucao
- Objetivo: impedir subir producao com defaults acidentais.

4. Reordenacao de fluxo no `deploy.sh`

- Ordem atual:
  1) preparar/garantir arquivo de ambiente
  2) executar `scripts/deploy_precheck.sh`
  3) seguir com deploy e validacoes pos-subida
- Evita precheck sem contexto de ambiente pronto.

5. Volume de autenticacao como externo (prod e staging)

- Auth SQLite foi fixado como volume externo com `name` explicito:
  - `infra/docker-compose.yml`
  - `infra/docker-compose.staging.yml`
- Evita recriacao acidental de volume e perda de referencia do `auth.db`.

### Como validar rapidamente

```bash
cd /opt/apps/portaleco-vps-monitor

# precheck por ambiente
./scripts/deploy_precheck.sh prod
./scripts/deploy_precheck.sh staging

# probe de login interno/publico
./scripts/auth_login_probe.sh prod
./scripts/auth_login_probe.sh staging

# deploy por ambiente
./deploy.sh prod
./deploy.sh staging
```

Observacoes operacionais:

- Em `staging`, probe publico pode permanecer em soft-fail quando DNS externo nao resolve (`staging.monitor.portalecomdo.com.br`).
- Esse comportamento nao bloqueia deploy de staging por padrao.

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

Tambem pode validar autenticacao:

- probe real de login/sessao em `prod`
- probe de `staging` (por padrao em soft-fail para evitar falso negativo por DNS externo)

Tambem pode validar uso de disco:

- `scripts/disk_guard_check.sh` com limites configuraveis

Se houver falha, retorna `exit 1` e opcionalmente envia webhook via:

- `ALERT_WEBHOOK_URL`
- arquivo local `infra/.health-alert.env` (nao versionado)
- flags opcionais:
  - `HEALTH_CHECK_AUTH_PROBE`
  - `HEALTH_CHECK_AUTH_PROBE_STAGING`
  - `HEALTH_CHECK_AUTH_PROBE_STAGING_SOFT_FAIL`
  - `HEALTH_CHECK_DISK_GUARD`
  - `DISK_WARN_THRESHOLD`
  - `DISK_FAIL_THRESHOLD`
  - `DISK_PATHS`

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

Script: `./scripts/release_preflight.sh [prod|staging|both]`

Valida automaticamente:

- variaveis criticas em `infra/.env` e `infra/.env.staging`
- containers `running/healthy` em prod e staging
- consistencia de auth (credencial em memoria x auth.db) por ambiente
- presenca das entradas de cron esperadas
- existencia de backup recente em `backups/`
- check de seguranca HTTP/rede via `scripts/security_check.sh` (prod e staging)
- check de superficie de portas no host via `scripts/host_surface_check.sh`
- check de uso de disco via `scripts/disk_guard_check.sh`

Exemplo:

```bash
cd /opt/apps/portaleco-vps-monitor
./scripts/release_preflight.sh prod
./scripts/release_preflight.sh staging
./scripts/release_preflight.sh both
```

## Security check

Script: `./scripts/security_check.sh [prod|staging]`

Valida:

- headers de seguranca (HSTS, CSP, nosniff, Referrer-Policy)
- exposicao de portas publicas (`0.0.0.0`) com allowlist de servicos esperados
- deteccao de superficie administrativa publica (`8088`, `9000`, `9443`) conforme `ADMIN_ACCESS_MODE`

Exemplos:

```bash
cd /opt/apps/portaleco-vps-monitor
./scripts/security_check.sh prod
./scripts/security_check.sh staging
```

Modo estrito opcional:

```bash
SECURITY_STRICT_ADMIN_SURFACE=true ./scripts/security_check.sh prod
```

- `ADMIN_ACCESS_MODE=tunnel_only`: falha quando detectar bind admin publico
- `ADMIN_ACCESS_MODE=lan_whitelist`: aceita bind admin publico e cobra controle por firewall

## Host surface check

Script: `./scripts/host_surface_check.sh`

Valida portas publicas escutando no host (0.0.0.0 / ::):

- permitidas por padrao: `22,80,443`
- observacao por padrao: `25` (`81` e tratado como esperado quando vinculado ao `nginx-proxy-manager`)
- administrativas monitoradas: `8088,9000,9443`

Modo estrito opcional:

```bash
HOST_SURFACE_STRICT_ADMIN=true ./scripts/host_surface_check.sh
```

- `ADMIN_ACCESS_MODE=tunnel_only`: porta admin publica vira erro
- `ADMIN_ACCESS_MODE=lan_whitelist`: porta admin publica e aceita (controle no firewall)

## Headers de seguranca no frontend

O frontend (Nginx) aplica headers HTTP de seguranca por padrao:

- `Strict-Transport-Security`
- `Content-Security-Policy`
- `X-Content-Type-Options: nosniff`
- `Referrer-Policy`

## Precheck de deploy

Script: `./scripts/deploy_precheck.sh [prod|staging]`

Valida por ambiente:

- arquivo `.env` correspondente
- `AUTH_FAIL_ON_INSECURE_DEFAULTS=true`
- `ALLOWED_ORIGINS` com `https://`
- `AUTH_TOKEN_SECRET` e `AUTH_PASSWORD` fora de default e com tamanho minimo
- `docker compose config` valido

## Gate de release (comando unico)

Script: `./scripts/release_gate.sh [prod|staging]`

Executa em sequencia:

- `deploy_precheck.sh`
- `release_smoke.sh`
- `release_preflight.sh`

Exemplos:

```bash
cd /opt/apps/portaleco-vps-monitor
./scripts/release_gate.sh prod
./scripts/release_gate.sh staging
```

Opcoes uteis:

- `RELEASE_GATE_SMOKE_PUBLIC=false` para pular smoke publico no gate
- `RELEASE_GATE_STRICT_ADMIN_SURFACE=true` para ativar falha em superficie admin publica
- `RELEASE_GATE_STRICT_HOST_SURFACE=true` para ativar falha em portas admin publicas no host

## Atalhos npm (operacao)

No diretorio raiz do projeto:

```bash
npm run preflight:prod
npm run preflight:staging
npm run preflight:both

npm run gate:prod
npm run gate:staging

npm run precheck:prod
npm run precheck:staging

npm run smoke:prod
npm run smoke:staging

npm run security:prod
npm run security:staging

npm run disk:guard
npm run host:surface
npm run log:maintain
npm run incident:snapshot
npm run incident:prune
npm run incident:prune:dry
npm run cron:check
npm run cron:apply
npm run status:ops
npm run status:ops:strict
npm run auth:check:prod
npm run auth:check:staging
npm run auth:probe:prod
npm run auth:probe:staging
npm run auth:repair:prod
npm run auth:repair:staging
npm run auth:selfheal:prod
npm run auth:selfheal:staging
```

`status:ops` mostra rapidamente: estado do Git, saude dos containers, HTTP de prod/staging, cron e backup mais recente.

Opcoes do `status:ops`:

- `OPS_STATUS_STRICT=true`: retorna `exit 1` se houver erro critico
- `OPS_STATUS_FAIL_ON_WARN=true`: retorna `exit 1` tambem para avisos
- `BACKUP_MAX_AGE_HOURS=48`: limite de idade para backup recente

## Auth consistency check

Script: `./scripts/auth_consistency_check.sh [prod|staging]`

Valida por ambiente:

- backend em execucao
- `AUTH_USERNAME`/`AUTH_PASSWORD` presentes no container
- credencial do ambiente valida no `auth.db`
- usuario ativo no `auth.db`

## Auth login probe

Script: `./scripts/auth_login_probe.sh [prod|staging]`

Valida por ambiente com teste real via dominio publico:

- login/sessao internos no container backend (obrigatorio)
- login `POST /api/auth/login` com credencial do `.env`
- recebimento de cookie de sessao
- `GET /api/auth/me` com cookie retornando `200`

Opcoes:

- `AUTH_LOGIN_PROBE_PUBLIC=false` para pular probe publico
- `AUTH_LOGIN_PROBE_SOFT_FAIL=true` para nao falhar quando o probe publico estiver indisponivel

## Auth repair from env

Script: `./scripts/auth_repair_from_env.sh [prod|staging]`

Uso recomendado quando login retorna `401` mesmo com senha correta no `.env`.

Acao:

- garante tabela `users` no `auth.db`
- cria usuario do `AUTH_USERNAME` se nao existir
- forca `password_hash` com `AUTH_PASSWORD` do ambiente
- forca `active=1`
- valida login internamente via `auth-store`

Depois do reparo:

```bash
npm run auth:check:prod
```

## Auth self-heal

Script: `./scripts/auth_selfheal.sh [prod|staging]`

Executa automaticamente:

1. `auth_consistency_check`
2. se falhar: `auth_repair_from_env` + novo check
3. `auth_login_probe`

Exemplos:

```bash
npm run auth:selfheal:prod
npm run auth:selfheal:staging
```

## Cron reconcile

Script: `./scripts/cron_reconcile.sh [--check|--apply]`

Gerencia um bloco de cron idempotente para:

- backup diario de auth
- healthcheck a cada 5 minutos
- status operacional por hora
- self-heal de auth em producao por hora (modo soft-fail para probe publico)
- manutencao de logs diariamente (`03:20`)
- limpeza de snapshots de incidente diariamente (`03:40`)

Exemplos:

```bash
npm run cron:check
npm run cron:apply
```

## Log maintain

Script: `./scripts/log_maintain.sh`

Funcao:

- rotaciona logs `portaleco-*.log` quando ultrapassarem tamanho maximo
- compacta arquivo rotacionado (`.gz`)
- remove rotacionados antigos por retencao

Variaveis:

- `MAX_BYTES` (padrao `5242880`)
- `RETENTION_DAYS` (padrao `14`)

## Incident snapshot

Script: `./scripts/incident_snapshot.sh`

Gera pacote de diagnostico em `backups/incidents/incident-<timestamp>.tgz` com:

- estado do git e ultimos commits
- status de containers e compose
- tail de logs dos containers do monitor
- preflight prod, ops status, health alert e auth probe
- cron atual e headers HTTP do dominio prod

Uso:

```bash
npm run incident:snapshot
```

## Incident prune

Script: `./scripts/incident_prune.sh [--apply|--dry-run]`

Remove snapshots de incidente antigos no diretorio `backups/incidents`.

Retencao padrao: `14` dias (ajustavel por `RETENTION_DAYS`).

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
