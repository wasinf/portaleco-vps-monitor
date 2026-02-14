#!/bin/bash

echo "===================================="
echo "PortalEco VPS Monitor - Deploy Script"
echo "===================================="

cd /opt/apps/portaleco-vps-monitor || exit

echo "Atualizando branch main..."
git checkout main
git pull

echo "Rebuildando containers..."
cd infra || exit
docker compose down
docker compose up -d --build

echo "Deploy finalizado com sucesso!"
