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

## Endpoints de autenticação

- `POST /api/auth/login`
- `GET /api/auth/me`
- `GET /api/auth/users`
- `POST /api/auth/change-password`
