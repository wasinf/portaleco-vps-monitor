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

- API: `GET /health`
- Frontend: `GET /`

Se algum teste falhar, o deploy termina com erro.

## Endpoints de autenticação

- `POST /api/auth/login`
- `GET /api/auth/me`
- `POST /api/auth/change-password`
- `GET /api/auth/users` (admin)
- `POST /api/auth/users` (admin)
- `PATCH /api/auth/users/:username/active` (admin)

## Observabilidade

Backend gera logs estruturados em JSON por requisicao com:

- `request_id` (tambem enviado no header `x-request-id`)
- metodo, path, status, latencia (`latency_ms`)
- IP de origem e usuario autenticado (quando existir)

Para silenciar logs HTTP: `LOG_LEVEL=silent`.
