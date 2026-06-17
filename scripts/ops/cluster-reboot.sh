#!/usr/bin/env bash
# =============================================================================
# cluster-reboot.sh — Reboot cluster nodes
# Raspberry Pi 5 SLURM Cluster
#
# Modes:
#   rolling  (default): Reboot compute nodes one at a time, keeping the cluster
#                       available for jobs throughout. Head node is rebooted last.
#   full:               Drain all jobs, reboot entire cluster simultaneously.
#
# Usage:
#   sudo bash cluster-reboot.sh             # rolling reboot (default)
#   sudo bash cluster-reboot.sh --mode full # full cluster reboot
#   sudo bash cluster-reboot.sh --force     # cancel jobs without waiting
#
# Run on pi-node0 as admin.
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
ADMIN_USER="admin"
MODE="rolling"
FORCE_MODE=false
DRAIN_WAIT=180   # Max seconds to wait per node

for arg in "$@"; do
    case "${arg}" in
        --mode=*)    MODE="${arg#--mode=}" ;;
        --mode)      log "WARN" "Use --mode=rolling or --mode=full"; die "Bad argument" ;;
        --force)     FORCE_MODE=true ;;
        --help)
            echo "Usage: $0 [--mode=rolling|full] [--force]"
            echo "  rolling (default): reboot compute nodes one by one, head node last"
            echo "  full:              drain all jobs and reboot everything at once"
            echo "  --force:           cancel running jobs instead of waiting"
            exit 0
            ;;
        *) die "Unknown argument: ${arg}" ;;
    esac
done

[[ "${MODE}" == "rolling" || "${MODE}" == "full" ]] || die "Invalid mode: ${MODE}. Use 'rolling' or 'full'."

remote_run() {
    local node="$1"; shift
    ssh -o BatchMode=yes -o ConnectTimeout=10 "${ADMIN_USER}@${node}" "sudo $*" 2>&1
}

is_reachable() { ping -c1 -W3 "$1" &>/dev/null; }

wait_for_node() {
    local node="$1"
    local timeout="${2:-120}"
    local elapsed=0
    log "INFO" "  Waiting for ${node} to come back online (up to ${timeout}s)..."
    while ! is_reachable "${node}"; do
        sleep 5
        elapsed=$((elapsed + 5))
        [[ "${elapsed}" -lt "${timeout}" ]] || { warn "  ${node} did not come back after ${timeout}s"; return 1; }
    done
    # Extra wait for services to start
    sleep 20
    log "INFO" "  ${node} is back online (${elapsed}s)"
}

drain_node() {
    local node="$1"
    log "INFO" "  Draining ${node}..."
    scontrol update NodeName="${node}" State=DRAIN Reason="Reboot $(date +%H:%M)" || \
        warn "  Could not drain ${node}"

    local waited=0
    while squeue -w "${node}" -h -t RUNNING 2>/dev/null | grep -q .; do
        if [[ "${FORCE_MODE}" == "true" ]] || [[ "${waited}" -ge "${DRAIN_WAIT}" ]]; then
            log "WARN" "  Cancelling jobs on ${node}..."
            squeue -w "${node}" -h -o %i | xargs -r scancel 2>/dev/null || true
            break
        fi
        log "INFO" "  Waiting for jobs on ${node} to finish (${waited}/${DRAIN_WAIT}s)..."
        sleep 15
        waited=$((waited + 15))
    done
    log "INFO" "  ${node} drained"
}

resume_node() {
    local node="$1"
    log "INFO" "  Resuming ${node}..."
    scontrol update NodeName="${node}" State=RESUME || warn "  Could not resume ${node}"
    sleep 5
    NODE_STATE=$(scontrol show node "${node}" 2>/dev/null | grep -oP 'State=\K\S+' | head -1 || echo "UNKNOWN")
    log "INFO" "  ${node} state: ${NODE_STATE}"
}

# =============================================================================
# ROLLING REBOOT
# =============================================================================
if [[ "${MODE}" == "rolling" ]]; then
    log "INFO" "====================================================="
    log "INFO" "  Rolling reboot of pi-cluster"
    log "INFO" "  Compute nodes: one at a time"
    log "INFO" "  Head node: last"
    log "INFO" "====================================================="

    systemctl is-active --quiet slurmctld || \
        warn "slurmctld not running — node state tracking will be limited"

    for node in "${COMPUTE_NODES[@]}"; do
        log "INFO" "--- Rebooting ${node} ---"

        if ! is_reachable "${node}"; then
            warn "${node} unreachable — skipping"
            continue
        fi

        drain_node "${node}"

        log "INFO" "  Rebooting ${node}..."
        remote_run "${node}" reboot || warn "  reboot command may have disconnected SSH (normal)"
        sleep 10

        wait_for_node "${node}" 180 || { warn "  Skipping ${node} resume — node did not respond"; continue; }

        # Verify slurmd is running after reboot
        SLURMD_STATUS=$(remote_run "${node}" systemctl is-active slurmd 2>/dev/null || echo "unknown")
        if [[ "${SLURMD_STATUS}" != "active" ]]; then
            warn "  slurmd not running on ${node} after reboot — attempting to start..."
            remote_run "${node}" systemctl start slurmd || warn "  Could not start slurmd on ${node}"
            sleep 5
        fi

        resume_node "${node}"
        log "INFO" "--- ${node} complete ---"
        echo ""
    done

    log "INFO" "All compute nodes rebooted. Rebooting head node (pi-node0)..."
    log "INFO" "The cluster will be unavailable during pi-node0 reboot."
    log "INFO" ""

    # Graceful controller shutdown before rebooting head node
    scontrol update NodeName=pi-node0 State=DRAIN Reason="Head node reboot" 2>/dev/null || true
    sleep 10
    systemctl stop slurmd    2>/dev/null || true
    systemctl stop slurmctld 2>/dev/null || true

    log "INFO" "Rebooting pi-node0..."
    sleep 3
    reboot
fi

# =============================================================================
# FULL REBOOT
# =============================================================================
if [[ "${MODE}" == "full" ]]; then
    log "INFO" "====================================================="
    log "INFO" "  Full cluster reboot"
    log "INFO" "  ALL nodes will reboot simultaneously"
    log "INFO" "  Cluster will be UNAVAILABLE during reboot"
    log "INFO" "====================================================="

    # Drain all nodes
    log "INFO" "Draining all nodes..."
    scontrol update NodeName=pi-node[0-3] State=DRAIN Reason="Full cluster reboot" 2>/dev/null || \
        warn "Could not drain nodes"

    # Wait for or cancel jobs
    WAITED=0
    while squeue -t RUNNING -h 2>/dev/null | grep -q .; do
        if [[ "${FORCE_MODE}" == "true" ]] || [[ "${WAITED}" -ge "${DRAIN_WAIT}" ]]; then
            log "WARN" "Cancelling all running jobs..."
            scancel --state=RUNNING 2>/dev/null || true
            break
        fi
        RUNNING=$(squeue -t RUNNING -h 2>/dev/null | wc -l)
        log "INFO" "${RUNNING} jobs still running (${WAITED}/${DRAIN_WAIT}s)..."
        sleep 15
        WAITED=$((WAITED + 15))
    done

    # Stop SLURM
    log "INFO" "Stopping SLURM on all nodes..."
    for node in "${COMPUTE_NODES[@]}"; do
        is_reachable "${node}" && remote_run "${node}" systemctl stop slurmd 2>/dev/null || true
    done
    systemctl stop slurmd    2>/dev/null || true
    systemctl stop slurmctld 2>/dev/null || true

    # Reboot compute nodes
    log "INFO" "Rebooting compute nodes..."
    for node in "${COMPUTE_NODES[@]}"; do
        if is_reachable "${node}"; then
            remote_run "${node}" reboot || true
            log "INFO" "  ${node}: reboot initiated"
        fi
    done

    sleep 5

    # Reboot head node last
    log "INFO" "Rebooting pi-node0 (head node)..."
    log "INFO" "====================================================="
    log "INFO" "  Full reboot initiated. Log ends here."
    log "INFO" "====================================================="
    sleep 3
    reboot
fi
