#!/usr/bin/env bash
# =============================================================================
# 04-chrony.sh — Head Node: NTP Server Configuration
# Raspberry Pi 5 SLURM Cluster (pi-node0)
#
# Configures pi-node0 as the cluster's NTP server.
# Upstream NTP: Debian pool + Cloudflare
# Downstream clients: 192.168.129.0/24 (all cluster nodes)
#
# WHY THIS MATTERS: MUNGE credentials expire after 300 seconds.
# Clock drift > ~5 minutes causes authentication failures cluster-wide.
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

command -v chronyc &>/dev/null || die "chrony is not installed. Run 01-base-system.sh first."

log "INFO" "=== Configuring Chrony (NTP server) on head node ==="

# =============================================================================
# Write chrony configuration
# =============================================================================
CHRONY_CONF="/etc/chrony/chrony.conf"
BACKUP="${CHRONY_CONF}.orig"

if [[ ! -f "${BACKUP}" ]]; then
    cp "${CHRONY_CONF}" "${BACKUP}"
    log "INFO" "Backed up original config to ${BACKUP}"
fi

cat > "${CHRONY_CONF}" << 'CHRONY_EOF'
# =============================================================================
# Chrony configuration for pi-node0 (cluster NTP server)
# =============================================================================

# Upstream NTP sources
pool 2.debian.pool.ntp.org iburst maxsources 4
pool time.cloudflare.com   iburst maxsources 2

# Allow all cluster nodes to query this server
allow 192.168.129.0/24

# Act as a time source of last resort (stratum 10 = low quality)
# Compute nodes will still sync even if internet is unavailable
local stratum 10

# Step the clock on first startup if off by more than 1 second (up to 3 times)
# After that, only slew (gradual adjustment)
makestep 1.0 3

# Sync RTC hardware clock
rtcsync

# State files
driftfile /var/lib/chrony/drift

# Logging
logdir /var/log/chrony
log measurements statistics tracking
CHRONY_EOF

log "INFO" "Chrony configuration written to ${CHRONY_CONF}"

# =============================================================================
# Enable and start chrony
# =============================================================================
systemctl enable chrony
systemctl restart chrony
log "INFO" "Chrony service restarted"

# Wait for initial synchronization
log "INFO" "Waiting for initial time synchronization (up to 30 seconds)..."
for i in $(seq 1 6); do
    sleep 5
    if chronyc tracking 2>/dev/null | grep -q "Reference ID"; then
        log "INFO" "Time synchronized"
        break
    fi
done

# =============================================================================
# Verification
# =============================================================================
log "INFO" "Current chrony status:"
chronyc tracking 2>&1 | tee -a "${LOG_FILE}"

log "INFO" "Chrony sources:"
chronyc sources -v 2>&1 | tee -a "${LOG_FILE}"

log "INFO" "=== Chrony configuration complete ==="
log "INFO" "Compute nodes should use 'server pi-node0 iburst prefer' in their chrony.conf"
log "INFO" "Next step: sudo bash 05-nfs-server.sh"
