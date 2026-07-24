#!/usr/bin/env bash
# =============================================================================
# 07-slurm-controller.sh — Head Node: SLURM Controller Setup
# Raspberry Pi 5 SLURM Cluster (pi-node0)
#
# Installs and configures:
#   - /etc/slurm/slurm.conf   (cluster-wide, must be identical on all nodes)
#   - /etc/slurm/cgroup.conf  (cluster-wide, must be identical on all nodes)
#   - slurmctld               (controller daemon — pi-node0 only)
#   - slurmd                  (compute daemon — pi-node0 participates as compute)
#
# Distributes slurm.conf and cgroup.conf to all compute nodes via SSH.
#
# Config matches the live working cluster (picluster) and node IPs from
# head-node/02-network.sh.
#
# Idempotent: safe to re-run
# Run as: sudo bash 07-slurm-controller.sh
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
[[ "$(hostname)" == "pi-node0" ]] || die "This script must run on pi-node0"

command -v slurmctld &>/dev/null || die "SLURM not installed. Run 01-base-system.sh first."
systemctl is-active --quiet munge || die "MUNGE is not running. Run 06-munge.sh first."

# =============================================================================
# Configuration (IPs match head-node/02-network.sh)
# =============================================================================
CLUSTER_NAME="picluster"
CONTROLLER_HOST="pi-node0"
COMPUTE_NODES=("pi-node1" "pi-node2" "pi-node3")
ADMIN_USER="admin"
SLURM_CONF_DIR="/etc/slurm"
SLURM_SPOOL_CTLD="/var/spool/slurm/ctld"
SLURM_SPOOL_D="/var/spool/slurm/d"

log "INFO" "=== Configuring SLURM controller on ${CONTROLLER_HOST} ==="

# =============================================================================
# Create required directories
# =============================================================================
log "INFO" "Creating SLURM directories..."
install -d -m 0755 -o slurm -g slurm \
    "${SLURM_SPOOL_CTLD}" \
    "${SLURM_SPOOL_D}" \
    /var/log/slurm \
    "${SLURM_CONF_DIR}"

# =============================================================================
# Write slurm.conf (matches live working options)
# =============================================================================
log "INFO" "Writing /etc/slurm/slurm.conf..."
cat > "${SLURM_CONF_DIR}/slurm.conf" << 'SLURM_CONF_EOF'
# =============================================================================
# slurm.conf — SLURM cluster configuration for picluster
# Raspberry Pi 5 x4, Debian Trixie, SLURM 24.11.5
#
# IMPORTANT: This file must be IDENTICAL on all nodes.
# NodeAddr values match head-node/02-network.sh.
# After any change: sudo scontrol reconfigure  (or restart slurmctld + slurmd)
# =============================================================================

# Cluster identity
ClusterName=picluster
SlurmctldHost=pi-node0

# Authentication
AuthType=auth/munge
CryptoType=crypto/munge

# Scheduling
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory

# Process tracking
ProctrackType=proctrack/linuxproc
TaskPlugin=task/affinity

# MPI default
MpiDefault=pmix

# Mail notifications
MailProg=/usr/local/bin/slurm-no-mail

# Logging
SlurmctldDebug=info
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdDebug=info
SlurmdLogFile=/var/log/slurm/slurmd.log

# Timeouts
SlurmctldTimeout=300
SlurmdTimeout=300
InactiveLimit=0
MinJobAge=300
KillWait=30
Waittime=0

# State persistence
StateSaveLocation=/var/spool/slurm/ctld
SlurmdSpoolDir=/var/spool/slurm/d

# PID files
SlurmctldPidFile=/var/run/slurmctld.pid
SlurmdPidFile=/var/run/slurmd.pid

# Ports
SlurmctldPort=6817
SlurmdPort=6818

# Return down nodes to service automatically
ReturnToService=2

# Node definitions (adjust RealMemory to actual available MB)
# IPs from head-node/02-network.sh
NodeName=pi-node0 NodeAddr=192.168.129.36 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN
NodeName=pi-node1 NodeAddr=192.168.129.37 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN
NodeName=pi-node2 NodeAddr=192.168.129.38 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN
NodeName=pi-node3 NodeAddr=192.168.129.39 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN

# Partition (all 4 nodes available)
PartitionName=compute Nodes=pi-node[0-3] Default=YES MaxTime=INFINITE State=UP
SLURM_CONF_EOF

chown slurm:slurm "${SLURM_CONF_DIR}/slurm.conf"
chmod 0644 "${SLURM_CONF_DIR}/slurm.conf"
log "INFO" "slurm.conf written"

# =============================================================================
# Write cgroup.conf (matches live: cgroups disabled)
# =============================================================================
log "INFO" "Writing /etc/slurm/cgroup.conf..."
cat > "${SLURM_CONF_DIR}/cgroup.conf" << 'CGROUP_CONF_EOF'
# =============================================================================
# cgroup.conf — SLURM cgroup plugin configuration
# Live cluster keeps cgroup enforcement disabled (proctrack/linuxproc).
# =============================================================================
CgroupPlugin=disabled
CgroupAutomount=yes
ConstrainCores=no
ConstrainRAMSpace=no
ConstrainDevices=no
CGROUP_CONF_EOF

chown slurm:slurm "${SLURM_CONF_DIR}/cgroup.conf"
chmod 0644 "${SLURM_CONF_DIR}/cgroup.conf"
log "INFO" "cgroup.conf written"

# =============================================================================
# Distribute configuration to compute nodes
# =============================================================================
log "INFO" "Distributing SLURM configuration to compute nodes..."

for node in "${COMPUTE_NODES[@]}"; do
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${ADMIN_USER}@${node}" true 2>/dev/null; then
        log "WARN" "Cannot reach ${node} via SSH — skipping config distribution"
        continue
    fi

    log "INFO" "Copying config to ${node}..."
    scp -q "${SLURM_CONF_DIR}/slurm.conf"  "${ADMIN_USER}@${node}:/tmp/slurm.conf"
    scp -q "${SLURM_CONF_DIR}/cgroup.conf" "${ADMIN_USER}@${node}:/tmp/cgroup.conf"

    ssh "${ADMIN_USER}@${node}" "sudo bash -s" << 'REMOTE_EOF'
set -euo pipefail
mkdir -p /etc/slurm /var/spool/slurm/d /var/log/slurm
mv /tmp/slurm.conf  /etc/slurm/slurm.conf
mv /tmp/cgroup.conf /etc/slurm/cgroup.conf
chown slurm:slurm /etc/slurm/slurm.conf /etc/slurm/cgroup.conf
chmod 0644 /etc/slurm/slurm.conf /etc/slurm/cgroup.conf
chown slurm:slurm /var/spool/slurm/d /var/log/slurm
chmod 0755 /var/spool/slurm/d /var/log/slurm
REMOTE_EOF

    log "INFO" "Config installed on ${node}"
done

# =============================================================================
# Start SLURM services on head node
# =============================================================================
log "INFO" "Starting slurmctld (controller)..."
systemctl enable slurmctld
systemctl restart slurmctld
sleep 3

if systemctl is-active --quiet slurmctld; then
    log "INFO" "slurmctld is running"
else
    log "ERROR" "slurmctld failed to start"
    journalctl -u slurmctld -n 30 | tee -a "${LOG_FILE}"
    die "slurmctld startup failed"
fi

log "INFO" "Starting slurmd (compute daemon on head node)..."
systemctl enable slurmd
systemctl restart slurmd
sleep 3

if systemctl is-active --quiet slurmd; then
    log "INFO" "slurmd is running on pi-node0"
else
    log "ERROR" "slurmd failed to start on pi-node0"
    journalctl -u slurmd -n 30 | tee -a "${LOG_FILE}"
    die "slurmd startup failed"
fi

# =============================================================================
# Start SLURM on compute nodes
# =============================================================================
log "INFO" "Starting slurmd on compute nodes..."

for node in "${COMPUTE_NODES[@]}"; do
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${ADMIN_USER}@${node}" true 2>/dev/null; then
        log "WARN" "Cannot reach ${node} — skipping slurmd start"
        continue
    fi

    ssh "${ADMIN_USER}@${node}" "sudo systemctl enable slurmd && sudo systemctl restart slurmd"
    sleep 2

    STATUS=$(ssh "${ADMIN_USER}@${node}" "systemctl is-active slurmd" 2>/dev/null || echo "unknown")
    if [[ "${STATUS}" == "active" ]]; then
        log "INFO" "slurmd running on ${node}"
    else
        log "WARN" "slurmd status on ${node}: ${STATUS}"
    fi
done

# =============================================================================
# Verification
# =============================================================================
log "INFO" "Waiting for nodes to register (15 seconds)..."
sleep 15

log "INFO" "=== SLURM cluster status ==="
sinfo 2>&1 | tee -a "${LOG_FILE}"

log "INFO" "=== Node details ==="
scontrol show nodes 2>&1 | grep -E "(NodeName|State|CPUTot|RealMemory)" | tee -a "${LOG_FILE}"

# Quick test job (default partition: compute)
log "INFO" "Running test job (srun hostname)..."
srun --nodes=1 --ntasks=1 --partition=compute hostname 2>&1 | tee -a "${LOG_FILE}" || \
    log "WARN" "Test job failed — nodes may not be fully up yet. Wait a moment and retry."

log "INFO" "=== SLURM controller setup complete ==="
log "INFO" "Cluster: ${CLUSTER_NAME} | Controller: ${CONTROLLER_HOST}"
log "INFO" ""
log "INFO" "Useful commands:"
log "INFO" "  sinfo                          — cluster status"
log "INFO" "  squeue                         — job queue"
log "INFO" "  srun --nodes=4 hostname        — run on all nodes"
log "INFO" "  sbatch job.sh                  — submit batch job"
log "INFO" "  scontrol show nodes            — detailed node info"
log "INFO" ""
log "INFO" "If nodes show as DOWN: scontrol update NodeName=pi-node[0-3] State=RESUME"
