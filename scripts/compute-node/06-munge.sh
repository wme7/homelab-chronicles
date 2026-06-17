#!/usr/bin/env bash
# =============================================================================
# 06-munge.sh — Compute Node: MUNGE Setup
# Raspberry Pi 5 SLURM Cluster (pi-node1 / pi-node2 / pi-node3)
#
# This script is run on a compute node AFTER head-node/06-munge.sh has already
# distributed the munge.key. It verifies the key is present and starts the
# MUNGE daemon.
#
# If the key has NOT been distributed yet (head node 06-munge.sh not run),
# this script will wait or prompt the user to distribute it manually.
#
# Idempotent: safe to re-run
# Run as: sudo bash 06-munge.sh
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

MUNGE_KEY="/etc/munge/munge.key"

log "INFO" "=== Configuring MUNGE on compute node $(hostname) ==="

# =============================================================================
# Ensure munge directories exist
# =============================================================================
for dir in /etc/munge /var/lib/munge /var/log/munge /run/munge; do
    mkdir -p "${dir}"
done

chown munge:munge /etc/munge /var/lib/munge /var/log/munge
chmod 0700 /etc/munge /var/lib/munge /var/log/munge
chown munge:munge /run/munge 2>/dev/null || true
chmod 0755 /run/munge 2>/dev/null || true

# =============================================================================
# Verify MUNGE key exists
# =============================================================================
if [[ ! -f "${MUNGE_KEY}" ]]; then
    log "WARN" "MUNGE key not found at ${MUNGE_KEY}"
    log "WARN" "The key must be distributed from pi-node0 first."
    log "WARN" "Option 1: Run head-node/06-munge.sh on pi-node0 (it distributes automatically)"
    log "WARN" "Option 2: Manual copy:"
    log "WARN" "  On pi-node0: sudo scp /etc/munge/munge.key admin@$(hostname):/tmp/munge.key"
    log "WARN" "  Then: sudo mv /tmp/munge.key ${MUNGE_KEY}"
    log "WARN" "  Then: sudo chown munge:munge ${MUNGE_KEY} && sudo chmod 0400 ${MUNGE_KEY}"
    die "MUNGE key missing — cannot continue"
fi

# =============================================================================
# Set correct permissions (idempotent)
# =============================================================================
chown munge:munge "${MUNGE_KEY}"
chmod 0400 "${MUNGE_KEY}"
log "INFO" "Key permissions: $(ls -la ${MUNGE_KEY})"
log "INFO" "Key MD5: $(md5sum ${MUNGE_KEY} | awk '{print $1}')"

# =============================================================================
# Start MUNGE
# =============================================================================
systemctl enable munge
systemctl restart munge
sleep 2

if systemctl is-active --quiet munge; then
    log "INFO" "MUNGE daemon running on $(hostname)"
else
    log "ERROR" "MUNGE failed to start"
    journalctl -u munge -n 30 | tee -a "${LOG_FILE}"
    die "MUNGE startup failed"
fi

# =============================================================================
# Verify local MUNGE
# =============================================================================
log "INFO" "Testing local MUNGE encode/decode..."
LOCAL_TEST=$(munge -n | unmunge 2>&1)
echo "${LOCAL_TEST}" | tee -a "${LOG_FILE}"
echo "${LOCAL_TEST}" | grep -q "STATUS:.*Success" || die "Local MUNGE test failed"
log "INFO" "Local MUNGE test: PASSED"

# =============================================================================
# Test cross-node MUNGE (from this node to pi-node0)
# =============================================================================
if ssh -o ConnectTimeout=5 -o BatchMode=yes admin@pi-node0 true 2>/dev/null; then
    log "INFO" "Testing MUNGE: $(hostname) -> pi-node0..."
    CROSS_TEST=$(munge -n | ssh admin@pi-node0 "sudo unmunge" 2>&1 || true)
    log "INFO" "Cross-node result: ${CROSS_TEST}"
    if echo "${CROSS_TEST}" | grep -q "STATUS:.*Success"; then
        log "INFO" "Cross-node MUNGE test: PASSED"
    else
        log "WARN" "Cross-node MUNGE test: FAILED — verify key MD5 matches pi-node0"
    fi
else
    log "WARN" "Cannot SSH to pi-node0 for cross-node MUNGE test (non-fatal)"
fi

log "INFO" "=== MUNGE configuration complete on $(hostname) ==="
log "INFO" "Next step: sudo bash 07-slurm-node.sh"
