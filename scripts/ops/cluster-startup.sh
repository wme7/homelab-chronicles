#!/usr/bin/env bash
# =============================================================================
# cluster-startup.sh — Start all cluster services in the correct order
# Raspberry Pi 5 SLURM Cluster
#
# Startup order:
#   1. MUNGE on all nodes
#   2. Mount USB SSD on pi-node0
#   3. NFS server on pi-node0
#   4. NFS mounts on compute nodes
#   5. slurmctld on pi-node0
#   6. slurmd on all nodes
#   7. Resume nodes left in DRAIN from prior shutdown/reboot
#   8. Verify cluster health
#
# Run on pi-node0 as: sudo bash cluster-startup.sh
# =============================================================================
set -euo pipefail

LOG_FILE="/var/log/pi-cluster-ops.log"
SCRIPT_NAME="$(basename "$0")"

log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] [${SCRIPT_NAME}] $*" | tee -a "${LOG_FILE}"
}

warn() { log "WARN" "$*"; }
die()  { log "ERROR" "$*"; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Must run as root on pi-node0"
[[ "$(hostname)" == "pi-node0" ]] || die "This script must run on pi-node0"

COMPUTE_NODES=("pi-node1" "pi-node2" "pi-node3")
ALL_NODES=("pi-node0" "pi-node1" "pi-node2" "pi-node3")
ADMIN_USER="admin"
ADMIN_KEY="/home/admin/.ssh/id_ed25519"
STORAGE_MOUNT="/mnt/storage"

log "INFO" "====================================================="
log "INFO" "  Starting pi-cluster"
log "INFO" "====================================================="

# Helper: run command on remote node
remote_run() {
    local node="$1"; shift
    ssh -i "${ADMIN_KEY}" -o BatchMode=yes -o ConnectTimeout=10 "${ADMIN_USER}@${node}" "sudo $*" 2>&1
}

# Helper: check if a node is reachable
is_reachable() {
    ping -c1 -W3 "$1" &>/dev/null
}

# =============================================================================
# Step 1: Start MUNGE on pi-node0
# =============================================================================
log "INFO" "Step 1/8: Starting MUNGE on pi-node0..."
systemctl start munge
systemctl is-active --quiet munge && log "INFO" "  MUNGE: OK" || die "  MUNGE failed to start on pi-node0"

# =============================================================================
# Step 2: Mount USB SSD
# =============================================================================
log "INFO" "Step 2/8: Mounting USB SSD..."
if mountpoint -q "${STORAGE_MOUNT}"; then
    log "INFO" "  ${STORAGE_MOUNT}: already mounted"
else
    mount "${STORAGE_MOUNT}" && log "INFO" "  ${STORAGE_MOUNT}: mounted" || \
        die "  Failed to mount ${STORAGE_MOUNT}"
fi

# =============================================================================
# Step 3: Start NFS server
# =============================================================================
log "INFO" "Step 3/8: Starting NFS server on pi-node0..."
systemctl start nfs-kernel-server
systemctl is-active --quiet nfs-kernel-server && log "INFO" "  NFS server: OK" || \
    die "  NFS server failed to start"
exportfs -ra
log "INFO" "  NFS exports refreshed"

# =============================================================================
# Step 4: Start MUNGE and mount NFS on compute nodes
# =============================================================================
log "INFO" "Step 4/8: Starting MUNGE and mounting NFS on compute nodes..."
for node in "${COMPUTE_NODES[@]}"; do
    log "INFO" "  Processing ${node}..."
    if ! is_reachable "${node}"; then
        warn "  ${node}: unreachable — skipping"
        continue
    fi

    # Start MUNGE
    remote_run "${node}" systemctl start munge && \
        log "INFO" "  ${node}: MUNGE started" || \
        warn "  ${node}: MUNGE start failed"

    # Mount NFS
    remote_run "${node}" mount -a && \
        log "INFO" "  ${node}: NFS mounts applied" || \
        warn "  ${node}: mount -a failed (non-fatal, may already be mounted)"
done

# =============================================================================
# Step 5: Start slurmctld on pi-node0
# =============================================================================
log "INFO" "Step 5/8: Starting slurmctld..."
systemctl start slurmctld
sleep 3
systemctl is-active --quiet slurmctld && log "INFO" "  slurmctld: OK" || \
    die "  slurmctld failed to start. Check: journalctl -u slurmctld -n 50"

# =============================================================================
# Step 6: Start slurmd on all nodes
# =============================================================================
log "INFO" "Step 6/8: Starting slurmd on all nodes..."

# pi-node0 first
systemctl start slurmd
systemctl is-active --quiet slurmd && log "INFO" "  pi-node0 slurmd: OK" || \
    warn "  pi-node0 slurmd failed to start"

# Compute nodes
for node in "${COMPUTE_NODES[@]}"; do
    if ! is_reachable "${node}"; then
        warn "  ${node}: unreachable — skipping slurmd"
        continue
    fi
    remote_run "${node}" systemctl start slurmd && \
        log "INFO" "  ${node} slurmd: OK" || \
        warn "  ${node} slurmd failed to start"
done

# =============================================================================
# Step 7: Resume nodes left in DRAIN from prior shutdown/reboot
# =============================================================================
log "INFO" "Step 7/8: Resuming SLURM nodes..."
sleep 5  # let slurmd register with slurmctld

if ! systemctl is-active --quiet slurmctld; then
    warn "  slurmctld not active — skipping resume"
else
    for node in "${ALL_NODES[@]}"; do
        if ! is_reachable "${node}"; then
            warn "  ${node}: unreachable — leaving drained"
            continue
        fi

        # Only resume if slurmd is actually running
        if [[ "${node}" == "pi-node0" ]]; then
            slurmd_ok=$(systemctl is-active slurmd 2>/dev/null || echo "failed")
        else
            slurmd_ok=$(remote_run "${node}" systemctl is-active slurmd 2>/dev/null | tr -d '\n' || echo "failed")
        fi

        if [[ "${slurmd_ok}" != "active" ]]; then
            warn "  ${node}: slurmd not active — skipping resume"
            continue
        fi

        state=$(scontrol show node "${node}" 2>/dev/null | grep -oP 'State=\K\S+' | head -1 || echo "UNKNOWN")
        reason=$(scontrol show node "${node}" 2>/dev/null | grep -oP 'Reason=\K.*' | head -1 || true)

        case "${state}" in
            *DRAIN*|*DOWN*)
                log "INFO" "  Resuming ${node} (was ${state}; reason: ${reason:-none})"
                scontrol update NodeName="${node}" State=RESUME \
                    && log "INFO" "  ${node}: RESUME issued" \
                    || warn "  ${node}: RESUME failed"
                ;;
            *)
                log "INFO" "  ${node}: already ${state} — no resume needed"
                ;;
        esac
    done

    sleep 5
fi

# =============================================================================
# Step 8: Verify cluster health
# =============================================================================
log "INFO" "Step 8/8: Verifying cluster health..."
sleep 10

log "INFO" ""
log "INFO" "=== SLURM node status ==="
sinfo -N -l 2>&1 | tee -a "${LOG_FILE}"

log "INFO" ""
log "INFO" "=== Service status summary ==="
printf "%-12s %-12s %-12s %-12s\n" "Node" "munge" "slurmctld" "slurmd" | tee -a "${LOG_FILE}"
printf "%-12s %-12s %-12s %-12s\n" "----------" "----------" "----------" "----------" | tee -a "${LOG_FILE}"

for node in "${ALL_NODES[@]}"; do
    if ! is_reachable "${node}"; then
        printf "%-12s %-12s %-12s %-12s\n" "${node}" "OFFLINE" "OFFLINE" "OFFLINE" | tee -a "${LOG_FILE}"
        continue
    fi

    if [[ "${node}" == "pi-node0" ]]; then
        MUNGE_STATUS=$(systemctl is-active munge 2>/dev/null | tr -d '\n' || echo "failed")
        SLURMD_STATUS=$(systemctl is-active slurmd 2>/dev/null | tr -d '\n' || echo "failed")
        SLURMCTLD_STATUS=$(systemctl is-active slurmctld 2>/dev/null | tr -d '\n' || echo "failed")
    else
        MUNGE_STATUS=$(remote_run "${node}" systemctl is-active munge 2>/dev/null | tr -d '\n' || echo "failed")
        SLURMD_STATUS=$(remote_run "${node}" systemctl is-active slurmd 2>/dev/null | tr -d '\n' || echo "failed")
        SLURMCTLD_STATUS="N/A"
    fi

    printf "%-12s %-12s %-12s %-12s\n" "${node}" "${MUNGE_STATUS}" "${SLURMCTLD_STATUS}" "${SLURMD_STATUS}" | tee -a "${LOG_FILE}"
done

log "INFO" ""
log "INFO" "====================================================="
log "INFO" "  Cluster startup complete"
log "INFO" "  Run 'sinfo' or 'scontrol show nodes' to verify"
log "INFO" "====================================================="
