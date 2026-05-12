#!/bin/bash
# ============================================================
# setup_exporters.sh — Run on VM1, VM2, and VM3
# Installs Node Exporter + NVIDIA DCGM Exporter as systemd services
# ============================================================

set -euo pipefail

NODE_EXPORTER_VERSION="1.8.1"
DCGM_EXPORTER_VERSION="3.3.5-3.4.0"

echo "==> [1/5] Creating prometheus system user..."
id -u prometheus &>/dev/null || useradd --no-create-home --shell /bin/false prometheus

# ─────────────────────────────────────────
# NODE EXPORTER
# ─────────────────────────────────────────
echo "==> [2/5] Downloading Node Exporter v${NODE_EXPORTER_VERSION}..."
cd /tmp
curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" \
  -o node_exporter.tar.gz

tar xzf node_exporter.tar.gz

# Stop service before replacing binary (avoids "Text file busy")
systemctl stop node_exporter 2>/dev/null || true
cp "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/local/bin/
chown prometheus:prometheus /usr/local/bin/node_exporter

echo "==> [3/5] Creating Node Exporter systemd service..."
cat > /etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus Node Exporter
Documentation=https://github.com/prometheus/node_exporter
After=network-online.target
Wants=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
Restart=on-failure
RestartSec=5s
ExecStart=/usr/local/bin/node_exporter \
  --collector.filesystem.mount-points-exclude='^/(sys|proc|dev|host|etc)($$|/)' \
  --collector.systemd \
  --collector.processes \
  --web.listen-address=":9100"

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node_exporter
systemctl restart node_exporter
echo "    node_exporter started on :9100"

# ─────────────────────────────────────────
# NVIDIA DCGM EXPORTER (GPU metrics)
# ─────────────────────────────────────────
echo "==> [4/5] Setting up DCGM Exporter (GPU)..."

# Check if NVIDIA driver is present
if ! command -v nvidia-smi &>/dev/null; then
  echo "    WARNING: nvidia-smi not found. Skipping DCGM exporter."
  echo "    Install NVIDIA drivers first, then re-run this section."
else
  # Pull via Docker (easiest on most distros)
  if command -v docker &>/dev/null; then
    echo "    Using Docker for DCGM Exporter..."
    # Remove existing container if present (idempotent re-run)
    docker rm -f dcgm-exporter 2>/dev/null || true
    docker run -d \
      --name dcgm-exporter \
      --restart unless-stopped \
      --gpus all \
      --cap-add SYS_ADMIN \
      -p 9400:9400 \
      "nvcr.io/nvidia/k8s/dcgm-exporter:${DCGM_EXPORTER_VERSION}-ubuntu22.04"
    echo "    dcgm-exporter started on :9400"
  else
    echo "    Docker not found. Install Docker or use the DCGM package directly:"
    echo "    https://developer.nvidia.com/dcgm"
  fi
fi

# ─────────────────────────────────────────
# FIREWALL: open exporter ports to VM4 only
# ─────────────────────────────────────────
echo "==> [5/5] Configuring firewall rules..."
# Replace VM4_IP with your actual monitoring server IP
VM4_IP="${VM4_IP:-10.0.0.4}"

if command -v ufw &>/dev/null; then
  ufw allow from "${VM4_IP}" to any port 9100 comment "Prometheus Node Exporter"
  ufw allow from "${VM4_IP}" to any port 9400 comment "DCGM GPU Exporter"
  echo "    UFW rules added for ${VM4_IP}"
elif command -v firewall-cmd &>/dev/null; then
  firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${VM4_IP}' port port='9100' protocol='tcp' accept"
  firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${VM4_IP}' port port='9400' protocol='tcp' accept"
  firewall-cmd --reload
  echo "    firewalld rules added for ${VM4_IP}"
fi

echo ""
echo "✅ Setup complete on $(hostname)"
echo "   Node Exporter : http://$(hostname -I | awk '{print $1}'):9100/metrics"
echo "   DCGM Exporter : http://$(hostname -I | awk '{print $1}'):9400/metrics"
