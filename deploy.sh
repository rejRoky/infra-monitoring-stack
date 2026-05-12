#!/bin/bash
# ============================================================
# deploy.sh — Run on VM4 (Monitoring Server)
# Bootstraps the full monitoring stack via Docker Compose
# ============================================================

set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> [1/6] Checking prerequisites..."
command -v docker    &>/dev/null || { echo "ERROR: Docker not installed. Aborting."; exit 1; }
command -v docker compose &>/dev/null || docker compose version &>/dev/null \
  || { echo "ERROR: docker compose not found. Install Docker Compose v2."; exit 1; }

if [ ! -f "${COMPOSE_DIR}/.env" ]; then
  echo "ERROR: .env file missing. Copy .env.example to .env and fill in secrets."
  exit 1
fi

echo "==> [2/6] Creating required directories..."
mkdir -p \
  "${COMPOSE_DIR}/prometheus/rules" \
  "${COMPOSE_DIR}/alertmanager" \
  "${COMPOSE_DIR}/grafana/provisioning/datasources" \
  "${COMPOSE_DIR}/grafana/provisioning/dashboards" \
  "${COMPOSE_DIR}/grafana/dashboards"

echo "==> [3/6] Setting file permissions..."
# Prometheus runs as uid 65534 (nobody)
chmod 644 "${COMPOSE_DIR}/prometheus/prometheus.yml"
chmod 644 "${COMPOSE_DIR}/prometheus/rules/"*.yml

# Alertmanager config
chmod 600 "${COMPOSE_DIR}/alertmanager/alertmanager.yml"  # contains secrets
chmod 600 "${COMPOSE_DIR}/.env"

echo "==> [4/6] Pulling latest images..."
docker compose --env-file "${COMPOSE_DIR}/.env" \
  -f "${COMPOSE_DIR}/docker-compose.yml" \
  pull

echo "==> [5/6] Starting services..."
docker compose --env-file "${COMPOSE_DIR}/.env" \
  -f "${COMPOSE_DIR}/docker-compose.yml" \
  up -d

echo "==> [6/6] Waiting for services to be healthy..."
sleep 10

services=(prometheus grafana alertmanager node-exporter)
for svc in "${services[@]}"; do
  status=$(docker inspect --format='{{.State.Health.Status}}' "${svc}" 2>/dev/null || echo "no-healthcheck")
  echo "    ${svc}: ${status}"
done

echo ""
echo "✅ Monitoring stack deployed on $(hostname)"
echo ""
echo "   Prometheus    → http://$(hostname -I | awk '{print $1}'):9090"
echo "   Grafana       → http://$(hostname -I | awk '{print $1}'):3000"
echo "   Alertmanager  → http://$(hostname -I | awk '{print $1}'):9093"
echo ""
echo "   Import Grafana dashboards:"
echo "     Node Exporter Full  → https://grafana.com/grafana/dashboards/1860"
echo "     NVIDIA DCGM         → https://grafana.com/grafana/dashboards/12239"
echo ""
echo "   Verify Prometheus targets:"
echo "     http://$(hostname -I | awk '{print $1}'):9090/targets"
