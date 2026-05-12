# Infrastructure Monitoring — Prometheus + Grafana

Centralized monitoring for 4 VM servers.  
Covers: CPU · RAM · Disk · Network · GPU (NVIDIA)

---

## Architecture

```text
VM1 (gpu-server)     172.22.8.114   :9100 Node Exporter · :9400 DCGM Exporter
VM2 (ml-workload)    TBD            :9100 Node Exporter · :9400 DCGM Exporter
VM3 (db-server)      TBD            :9100 Node Exporter
VM4 (monitoring)     localhost      :9090 Prometheus · :3000 Grafana · :9093 Alertmanager
```

---

## File Structure

```text
infra-monitoring-stack/
├── .env                              # Secrets (never commit)
├── .env.example                      # Template — copy to .env and fill in
├── .gitignore
├── README.md
├── docker-compose.yml                # VM4: full monitoring stack
├── alertmanager/
│   └── alertmanager.yml              # Alert routing: Slack, PagerDuty, Email
├── grafana/
│   ├── dashboards/                   # Auto-provisioned dashboard JSON files
│   │   ├── node-exporter-full.json
│   │   └── dcgm-exporter.json
│   └── provisioning/
│       ├── datasources/prometheus.yml
│       └── dashboards/dashboards.yml
├── prometheus/
│   ├── prometheus.yml                # Scrape configs for all VMs
│   └── rules/
│       ├── cpu_memory.yml
│       ├── disk.yml
│       ├── gpu.yml
│       └── instance.yml
└── scripts/
    ├── deploy.sh                     # Bootstrap VM4 monitoring stack
    └── setup_exporters.sh            # Run on VM1, VM2, VM3
```

---

## Step-by-Step Deployment

### Step 1 — Configure secrets (VM4)

```bash
cp .env.example .env
```

Edit `.env` and fill in:

| Variable | Description |
| --- | --- |
| `GRAFANA_ADMIN_PASSWORD` | Grafana login password |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook URL |
| `PAGERDUTY_ROUTING_KEY` | PagerDuty integration key |
| `SMTP_PASSWORD` | Gmail app password for email alerts |

> **Note:** `alertmanager/alertmanager.yml` references these as `${VAR}` placeholders.  
> Alertmanager does **not** expand env vars natively — replace the placeholders with real values before deploying.

---

### Step 2 — Add VM IPs to Prometheus

Edit `prometheus/prometheus.yml` — fill in vm2 and vm3 IPs:

```yaml
# node_exporter job — uncomment and set real IPs
- targets: ["<VM2_IP>:9100"]
  labels:
    instance: "vm2"
- targets: ["<VM3_IP>:9100"]
  labels:
    instance: "vm3"

# dcgm_exporter job — GPU VMs only
- targets: ["<VM2_IP>:9400"]
  labels:
    instance: "vm2"
```

---

### Step 3 — Set up exporters on VM1, VM2, VM3

```bash
# Copy script to each VM
scp scripts/setup_exporters.sh user@<VM_IP>:~/

# SSH in and run as root
ssh user@<VM_IP>
sudo VM4_IP=<VM4_IP> bash setup_exporters.sh
```

The script installs:

- **Node Exporter** (port 9100) — as a systemd service
- **DCGM Exporter** (port 9400) — via Docker, only if NVIDIA GPU + drivers detected

> **GPU VMs:** Docker and NVIDIA Container Toolkit must be installed before running.  
> See the GPU setup section below.

Verify:

```bash
curl http://localhost:9100/metrics | head -10
curl http://localhost:9400/metrics | head -10   # GPU VMs only
```

---

### Step 4 — Deploy monitoring stack on VM4

```bash
chmod +x scripts/deploy.sh
sudo bash scripts/deploy.sh
```

> **No GPU on VM4?** The `dcgm-exporter` service uses `profiles: [gpu]` and will be skipped automatically.

---

### Step 5 — Verify

Open `http://<VM4_IP>:9090/targets` — all targets should show **State: UP**.

---

### Step 6 — View Data in Grafana

Open `http://<VM4_IP>:3000` → login with your `.env` credentials.

Go to **Dashboards** from the left sidebar. Two dashboards are auto-provisioned:

**Node Exporter Full** — CPU, RAM, Disk, Network

| Dropdown | Value |
| --- | --- |
| `job` | `node_exporter` |
| `instance` | `vm1` / `vm2` / `vm3` / `vm4` |

**NVIDIA DCGM Exporter Dashboard** — GPU utilization, VRAM, temperature, power

| Dropdown | Value |
| --- | --- |
| `instance` | `vm1` (or whichever GPU VM) |
| `gpu` | `0` |

> Set time range to **Last 1 hour** and auto-refresh to **30s** (top-right corner).

---

## GPU Setup (NVIDIA Container Toolkit)

Required on any VM running the DCGM exporter:

```bash
# 1. Install NVIDIA Container Toolkit
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt update && apt install -y nvidia-container-toolkit

# 2. Configure Docker runtime
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# 3. Run DCGM exporter
docker run -d \
  --name dcgm-exporter \
  --restart unless-stopped \
  --gpus all \
  --cap-add SYS_ADMIN \
  -p 9400:9400 \
  nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04
```

---

## Common Commands

```bash
# Reload Prometheus config without restart
curl -X POST http://localhost:9090/-/reload

# Reload Grafana dashboard provisioning
curl -X POST http://admin:<password>@localhost:3000/api/admin/provisioning/dashboards/reload

# Check Alertmanager status
curl http://localhost:9093/api/v2/status

# View active alerts
curl http://localhost:9093/api/v2/alerts

# Restart a single service
docker compose restart prometheus

# View logs
docker compose logs -f prometheus
docker compose logs -f grafana
docker compose logs -f alertmanager

# Stop everything
docker compose down

# Stop and wipe all data (DESTRUCTIVE)
docker compose down -v
```

---

## Key PromQL Queries

```promql
# CPU usage per instance (%)
100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[2m])) * 100)

# RAM available (%)
(node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# Disk usage per mount (%)
100 - ((node_filesystem_avail_bytes / node_filesystem_size_bytes) * 100)

# GPU utilization (%)
DCGM_FI_DEV_GPU_UTIL

# GPU VRAM usage (%)
(DCGM_FI_DEV_FB_USED / (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE)) * 100

# GPU temperature (°C)
DCGM_FI_DEV_GPU_TEMP

# GPU power draw (W)
DCGM_FI_DEV_POWER_USAGE

# Network in (Mbps)
rate(node_network_receive_bytes_total{device!~"lo"}[5m]) * 8 / 1024 / 1024
```

---

## Troubleshooting

### Prometheus / Grafana: permission denied on config files

Docker containers run as non-root users (Prometheus: uid 65534, Grafana: uid 472).  
If your project is under `/home/<user>/`, the home directory must be traversable:

```bash
chmod o+x /home/<user>
```

### Grafana dashboards not showing

```bash
# Reload provisioning without restarting
curl -X POST http://admin:<password>@localhost:3000/api/admin/provisioning/dashboards/reload

# Confirm dashboards exist
curl -s http://admin:<password>@localhost:3000/api/search?type=dash-db | python3 -m json.tool
```

### Alertmanager crash: unsupported scheme or field not found

Alertmanager does not expand environment variables. Replace `${VAR}` placeholders in  
`alertmanager/alertmanager.yml` with real values before starting.

### setup_exporters.sh: Text file busy

The script is idempotent — safe to re-run. It stops node_exporter before replacing the binary  
and removes the existing dcgm-exporter container before recreating it.

### DCGM exporter: no known GPU vendor found

NVIDIA Container Toolkit is not configured. Run the GPU setup steps in this README,  
then `docker rm -f dcgm-exporter` and re-run the docker run command.

---

## Ports Summary

| Service | Port | Purpose |
| --- | --- | --- |
| Node Exporter | 9100 | OS metrics (all VMs) |
| DCGM Exporter | 9400 | GPU metrics (NVIDIA) |
| Prometheus | 9090 | Metrics DB + query UI |
| Grafana | 3000 | Dashboards |
| Alertmanager | 9093 | Alert routing |
