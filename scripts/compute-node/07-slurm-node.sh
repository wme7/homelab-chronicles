#!/usr/bin/env bash
# =============================================================================
# 07-slurm-node.sh — Compute Node: SLURM Compute Daemon Setup
# Raspberry Pi 5 SLURM Cluster (pi-node1 / pi-node2 / pi-node3)
#
# Configures and starts slurmd on a compute node.
# slurm.conf is received from pi-node0 (by head-node/07-slurm-controller.sh).
# If not yet received, this script will attempt to fetch it via SCP.
#
# Idempotent: safe to re-run
# Run as: sudo bash 07-slurm-node.sh
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

command -v slurmd &>/dev/null || die "slurmd not installed. Run 01-base-system.sh first."
systemctl is-active --quiet munge || die "MUNGE is not running. Run 06-munge.sh first."

SLURM_CONF="/etc/slurm/slurm.conf"
CGROUP_CONF="/etc/slurm/cgroup.conf"
HEAD_NODE="pi-node0"
ADMIN_USER="admin"

log "INFO" "=== Configuring SLURM compute node on $(hostname) ==="

# =============================================================================
# Fetch slurm.conf from head node if not present
# =============================================================================
if [[ ! -f "${SLURM_CONF}" ]]; then
    log "INFO" "${SLURM_CONF} not found — fetching from ${HEAD_NODE}..."

    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${ADMIN_USER}@${HEAD_NODE}" true 2>/dev/null; then
        die "Cannot SSH to ${HEAD_NODE}. Ensure SSH is configured and head-node setup is complete."
    fi

    mkdir -p /etc/slurm

    scp "${ADMIN_USER}@${HEAD_NODE}:/etc/slurm/slurm.conf"  /etc/slurm/slurm.conf
    scp "${ADMIN_USER}@${HEAD_NODE}:/etc/slurm/cgroup.conf" /etc/slurm/cgroup.conf

    chown slurm:slurm /etc/slurm/slurm.conf /etc/slurm/cgroup.conf
    chmod 0644 /etc/slurm/slurm.conf /etc/slurm/cgroup.conf

    log "INFO" "SLURM config fetched from ${HEAD_NODE}"
else
    log "INFO" "SLURM config already present at ${SLURM_CONF}"
fi

# =============================================================================
# Verify slurm.conf references this node
# =============================================================================
THIS_HOST=$(hostname)
if ! grep -q "NodeName=${THIS_HOST}" "${SLURM_CONF}"; then
    log "WARN" "Warning: ${THIS_HOST} is not defined in ${SLURM_CONF}"
    log "WARN" "Check that slurm.conf was distributed correctly from pi-node0"
fi

# =============================================================================
# Create SLURM directories
# =============================================================================
install -d -m 0755 -o slurm -g slurm \
    /var/spool/slurmd \
    /var/log/slurm

# =============================================================================
# Enable and start slurmd
# =============================================================================
log "INFO" "Starting slurmd..."
systemctl enable slurmd
systemctl restart slurmd
sleep 3

if systemctl is-active --quiet slurmd; then
    log "INFO" "slurmd is running on $(hostname)"
else
    log "ERROR" "slurmd failed to start"
    journalctl -u slurmd -n 50 | tee -a "${LOG_FILE}"
    die "slurmd startup failed"
fi

# =============================================================================
# Verify from controller
# =============================================================================
log "INFO" "Checking node registration with controller..."
sleep 5

NODE_STATE=$(ssh -o BatchMode=yes "${ADMIN_USER}@${HEAD_NODE}" \
    "scontrol show node ${THIS_HOST} 2>/dev/null | grep 'State=' | awk -F= '{print \$2}' | awk '{print \$1}'" \
    2>/dev/null || echo "UNREACHABLE")

log "INFO" "Node state as seen by controller: ${NODE_STATE}"

case "${NODE_STATE}" in
    IDLE|ALLOCATED|MIXED)
        log "INFO" "Node $(hostname) is registered and ${NODE_STATE} — OK"
        ;;
    DOWN*|DRAIN*)
        log "WARN" "Node is ${NODE_STATE}. Run on pi-node0:"
        log "WARN" "  sudo scontrol update NodeName=${THIS_HOST} State=RESUME"
        ;;
    UNKNOWN)
        log "WARN" "Node is UNKNOWN — slurmd may still be registering. Wait and check: sinfo"
        ;;
    *)
        log "WARN" "Unexpected node state: ${NODE_STATE}"
        ;;
esac

log "INFO" "=== SLURM compute node setup complete on $(hostname) ==="
log "INFO" ""
log "INFO" "To verify from pi-node0:"
log "INFO" "  sinfo"
log "INFO" "  scontrol show node $(hostname)"
log "INFO" ""
log "INFO" "If node shows DOWN: sudo scontrol update NodeName=$(hostname) State=RESUME"
