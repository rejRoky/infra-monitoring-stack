# Infrastructure Monitoring — Prometheus + Grafana

Centralized monitoring for 4 VM servers.  
Covers: CPU · RAM · Disk · Network · GPU (NVIDIA)

---

## Architecture

```
VM1 (app-server)    :9100 Node Exporter
VM2 (ml-workload)   :9100 Node Exporter · :9400 DCGM Exporter
VM3 (db-server)     :9100 Node Exporter
VM4 (monitoring)    :9090 Prometheus · :3000 Grafana · :9093 Alertmanager
```

---

## File Structure

```
monitoring/
├── vm1-vm2-vm3/
│   └── setup_exporters.sh        # Run on VM1, VM2, VM3
└── vm4/
    ├── docker-compose.yml
    ├── deploy.sh                  # Bootstrap script for VM4
    ├── .env                       # Secrets (never commit)
    ├── prometheus/
    │   ├── prometheus.yml
    │   └── rules/
    │       ├── cpu_memory.yml
    │       ├── disk.yml
    │       ├── gpu.yml
    │       └── instance.yml
    ├── alertmanager/
    │   └── alertmanager.yml
    └── grafana/
        ├── provisioning/
        │   ├── datasources/prometheus.yml
        │   └── dashboards/dashboards.yml
        └── dashboards/            # Drop custom dashboard JSON here
```

---

## Step-by-Step Deployment

### Step 1 — VM1, VM2, VM3

```bash
# Copy setup_exporters.sh to each VM, then:
export VM4_IP=10.0.0.4    # your actual VM4 IP
chmod +x setup_exporters.sh
sudo bash setup_exporters.sh
```

Verify:
```bash
curl http://localhost:9100/metrics | head -20
curl http://localhost:9400/metrics | head -20   # GPU VMs only
```

---

### Step 2 — VM4 (Monitoring Server)

1. Edit `prometheus/prometheus.yml` — replace all `10.0.0.X` with real VM IPs.
2. Edit `.env` — fill in Slack webhook, PagerDuty key, SMTP password, Grafana password.
3. If VM4 has no GPU, comment out the `dcgm-exporter` service in `docker-compose.yml`.

```bash
chmod +x deploy.sh
sudo bash deploy.sh
```

---

### Step 3 — Import Grafana Dashboards

Login at `http://VM4_IP:3000` with your `.env` credentials, then:

| Dashboard | Import ID |
|---|---|
| Node Exporter Full | `1860` |
| NVIDIA DCGM Exporter | `12239` |
| Alertmanager | `9578` |

Go to **Dashboards → Import → Enter ID → Load**.

---

### Step 4 — Verify Prometheus Targets

Open `http://VM4_IP:9090/targets`  
All targets should show **State: UP** with a green badge.

---

## Common Commands

```bash
# Reload Prometheus config without restart
curl -X POST http://localhost:9090/-/reload

# Check Alertmanager status
curl http://localhost:9093/api/v2/status

# View active alerts
curl http://localhost:9093/api/v2/alerts

# Restart a single service
docker compose restart prometheus

# View logs
docker compose logs -f prometheus
docker compose logs -f alertmanager

# Stop everything
docker compose down

# Stop and wipe all data (DESTRUCTIVE)
docker compose down -v
```

---

## Key Prometheus Queries (PromQL)

```promql
# CPU usage per instance (%)
100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[2m])) * 100)

# RAM available (%)
(node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# Disk usage per mount (%)
100 - ((node_filesystem_avail_bytes / node_filesystem_size_bytes) * 100)

# GPU utilization per instance
DCGM_FI_DEV_GPU_UTIL

# GPU VRAM usage (%)
(DCGM_FI_DEV_FB_USED / (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE)) * 100

# GPU temperature
DCGM_FI_DEV_GPU_TEMP

# Network in (Mbps)
rate(node_network_receive_bytes_total{device!~"lo"}[5m]) * 8 / 1024 / 1024
```

---

## Ports Summary

| Service | Port | Purpose |
|---|---|---|
| Node Exporter | 9100 | OS metrics (all VMs) |
| DCGM Exporter | 9400 | GPU metrics |
| Prometheus | 9090 | Metrics DB + query UI |
| Grafana | 3000 | Dashboards |
| Alertmanager | 9093 | Alert routing |
