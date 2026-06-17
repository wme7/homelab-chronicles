#!/usr/bin/env bash
# =============================================================================
# 04-chrony.sh — Compute Node: NTP Client Configuration
# Raspberry Pi 5 SLURM Cluster (pi-node1 / pi-node2 / pi-node3)
#
# Configures this compute node to use pi-node0 as its primary NTP server.
# Falls back to Debian pool if pi-node0 is unreachable.
#
# Idempotent: safe to re-run
# Run as: sudo bash 04-chrony.sh
# =============================================================================
set -euo pipefail

LOG_FILE="/var/log/pi-cluster-setup.log"
SCRIPT_NAME="$(basename "$0")"

log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] [${SCRIPT_NAME}] $*" | tee -a "${LOG_FILE}"
}

die() { log "ERROR" "$*"; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Must run as root"

command -v chronyc &>/dev/null || die "chrony not installed. Run 01-base-system.sh first."

log "INFO" "=== Configuring Chrony NTP client on $(hostname) ==="

CHRONY_CONF="/etc/chrony/chrony.conf"
BACKUP="${CHRONY_CONF}.orig"

[[ -f "${BACKUP}" ]] || cp "${CHRONY_CONF}" "${BACKUP}"

cat > "${CHRONY_CONF}" << 'CHRONY_EOF'
# =============================================================================
# Chrony configuration for compute nodes
# Primary NTP: pi-node0 (cluster head node)
# =============================================================================

# Primary: cluster head node (prefer = highest priority)
server pi-node0 iburst prefer

# Fallback: public NTP if pi-node0 unreachable
pool 2.debian.pool.ntp.org iburst maxsources 2

# Step the clock on startup if off by more than 1 second (up to 3 times)
makestep 1.0 3

# Sync hardware RTC
rtcsync

driftfile /var/lib/chrony/drift
logdir /var/log/chrony
CHRONY_EOF

systemctl enable chrony
systemctl restart chrony
log "INFO" "Chrony restarted"

# Wait for sync
log "INFO" "Waiting for time synchronization (up to 30 seconds)..."
for i in $(seq 1 6); do
    sleep 5
    if chronyc tracking 2>/dev/null | grep -q "Reference ID"; then
        break
    fi
done

log "INFO" "Chrony sources:"
chronyc sources -v 2>&1 | tee -a "${LOG_FILE}"

log "INFO" "Chrony tracking:"
chronyc tracking 2>&1 | tee -a "${LOG_FILE}"

# Check if synced to pi-node0
if chronyc sources 2>/dev/null | grep -q "pi-node0"; then
    log "INFO" "Synchronized to pi-node0 — OK"
else
    log "WARN" "Not yet synchronized to pi-node0. Check pi-node0 chrony is running and ports are open."
fi

log "INFO" "=== Chrony client configuration complete on $(hostname) ==="
log "INFO" "Next step: sudo bash 05-nfs-client.sh"
