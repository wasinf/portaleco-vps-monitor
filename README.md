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

## Autenticação do dashboard

As rotas `/api/*` são protegidas por token Bearer (exceto `/api/auth/login`).

Configuração recomendada:

1. Copiar `infra/.env.example` para `infra/.env`
2. Alterar `AUTH_USERNAME`, `AUTH_PASSWORD` e `AUTH_TOKEN_SECRET`
3. Subir/rebuildar com Docker Compose

Exemplo:

```bash
cd /opt/apps/portaleco-vps-monitor/infra
cp .env.example .env
docker compose up -d --build
```
