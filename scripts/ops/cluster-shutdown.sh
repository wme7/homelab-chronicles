#!/usr/bin/env bash
# =============================================================================
# cluster-shutdown.sh — Gracefully shut down the entire cluster
# Raspberry Pi 5 SLURM Cluster
#
# Shutdown order:
#   1. Drain all SLURM nodes (stop accepting new jobs)
#   2. Wait for running jobs to finish (or force-cancel after timeout)
#   3. Stop slurmd on compute nodes
#   4. Stop slurmctld on pi-node0
#   5. Unmount NFS on compute nodes
#   6. Stop NFS server on pi-node0
#   7. Stop MUNGE on all nodes
#   8. Shutdown compute nodes
#   9. Shutdown pi-node0
#
# Run on pi-node0 as: sudo bash cluster-shutdown.sh [--force]
#   --force: cancel running jobs immediately without waiting
#
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
STORAGE_MOUNT="/shared"
DRAIN_WAIT_SECONDS=300   # Max time to wait for jobs to complete
FORCE_MODE=false

# Parse arguments
for arg in "$@"; do
    case "${arg}" in
        --force) FORCE_MODE=true; log "WARN" "Force mode enabled — running jobs will be cancelled" ;;
        *) die "Unknown argument: ${arg}" ;;
    esac
done

remote_run() {
    local node="$1"; shift
    ssh -i "${ADMIN_KEY}" -o BatchMode=yes -o ConnectTimeout=10 "${ADMIN_USER}@${node}" "sudo $*" 2>&1 || true
}

is_reachable() {
    ping -c1 -W3 "$1" &>/dev/null
}

log "INFO" "====================================================="
log "INFO" "  Shutting down pi-cluster"
if [[ "${FORCE_MODE}" == "true" ]]; then
    log "WARN" "  FORCE MODE: jobs will be cancelled"
fi
log "INFO" "====================================================="

# =============================================================================
# Step 1: Drain all nodes
# =============================================================================
log "INFO" "Step 1/9: Draining all SLURM nodes..."
if command -v scontrol &>/dev/null && systemctl is-active --quiet slurmctld; then
    scontrol update NodeName=pi-node[0-3] State=DRAIN Reason="Cluster shutdown $(date)" || \
        warn "Could not drain nodes (controller may not be running)"
    log "INFO" "  All nodes drained (no new jobs will start)"
else
    warn "  slurmctld not running — skipping drain"
fi

# =============================================================================
# Step 2: Wait for running jobs or force-cancel
# =============================================================================
log "INFO" "Step 2/9: Waiting for running jobs to complete..."
WAITED=0
while true; do
    RUNNING=$(squeue -t RUNNING -h 2>/dev/null | wc -l || echo 0)
    PENDING=$(squeue -t PENDING -h 2>/dev/null | wc -l || echo 0)

    if [[ "${RUNNING}" -eq 0 && "${PENDING}" -eq 0 ]]; then
        log "INFO" "  No jobs running or pending — proceeding"
        break
    fi

    if [[ "${FORCE_MODE}" == "true" ]] || [[ "${WAITED}" -ge "${DRAIN_WAIT_SECONDS}" ]]; then
        log "WARN" "  Cancelling ${RUNNING} running and ${PENDING} pending jobs..."
        scancel --state=RUNNING 2>/dev/null || true
        scancel --state=PENDING 2>/dev/null || true
        sleep 5
        break
    fi

    log "INFO" "  ${RUNNING} running, ${PENDING} pending... waiting (${WAITED}/${DRAIN_WAIT_SECONDS}s)"
    sleep 30
    WAITED=$((WAITED + 30))
done

# =============================================================================
# Step 3: Stop slurmd on compute nodes
# =============================================================================
log "INFO" "Step 3/9: Stopping slurmd on compute nodes..."
for node in "${COMPUTE_NODES[@]}"; do
    if is_reachable "${node}"; then
        remote_run "${node}" systemctl stop slurmd
        log "INFO" "  ${node}: slurmd stopped"
    else
        warn "  ${node}: unreachable"
    fi
done

# =============================================================================
# Step 4: Stop slurmctld and slurmd on pi-node0
# =============================================================================
log "INFO" "Step 4/9: Stopping SLURM services on pi-node0..."
systemctl stop slurmd    2>/dev/null && log "INFO" "  slurmd stopped"    || warn "  slurmd was not running"
systemctl stop slurmctld 2>/dev/null && log "INFO" "  slurmctld stopped" || warn "  slurmctld was not running"

# =============================================================================
# Step 5: Unmount NFS on compute nodes
# =============================================================================
log "INFO" "Step 5/9: Unmounting NFS on compute nodes..."
for node in "${COMPUTE_NODES[@]}"; do
    if is_reachable "${node}"; then
        #remote_run "${node}" "umount -l /shared /home/user 2>/dev/null || true"
        remote_run "${node}" "umount -l /shared 2>/dev/null || true"
        log "INFO" "  ${node}: NFS unmounted"
    else
        warn "  ${node}: unreachable — cannot unmount NFS"
    fi
done

# =============================================================================
# Step 6: Stop NFS server and unmount storage
# =============================================================================
log "INFO" "Step 6/9: Stopping NFS server..."
systemctl stop nfs-kernel-server 2>/dev/null && log "INFO" "  NFS server stopped" || true
sync
if mountpoint -q "${STORAGE_MOUNT}"; then
    umount "${STORAGE_MOUNT}" && log "INFO" "  ${STORAGE_MOUNT} unmounted" || \
        warn "  Could not unmount ${STORAGE_MOUNT} (lazy unmount)"
fi

# =============================================================================
# Step 7: Stop MUNGE on all nodes
# =============================================================================
log "INFO" "Step 7/9: Stopping MUNGE on all nodes..."
for node in "${COMPUTE_NODES[@]}"; do
    if is_reachable "${node}"; then
        remote_run "${node}" systemctl stop munge
        log "INFO" "  ${node}: MUNGE stopped"
    fi
done
systemctl stop munge 2>/dev/null && log "INFO" "  pi-node0: MUNGE stopped" || true

# =============================================================================
# Step 8: Shutdown compute nodes
# =============================================================================
log "INFO" "Step 8/9: Shutting down compute nodes..."
for node in "${COMPUTE_NODES[@]}"; do
    if is_reachable "${node}"; then
        remote_run "${node}" shutdown -h now
        log "INFO" "  ${node}: shutdown initiated"
    else
        warn "  ${node}: unreachable — may already be off"
    fi
done

log "INFO" "Waiting 20 seconds for compute nodes to shut down..."
sleep 20

# =============================================================================
# Step 9: Shutdown pi-node0
# =============================================================================
log "INFO" "Step 9/9: Shutting down pi-node0..."
log "INFO" "====================================================="
log "INFO" "  Cluster shutdown complete. Powering off pi-node0."
log "INFO" "====================================================="
shutdown -h now
