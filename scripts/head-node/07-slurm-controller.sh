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

command -v slurmctld &>/dev/null || die "SLURM not installed. Run 01-base-system.sh first."
systemctl is-active --quiet munge || die "MUNGE is not running. Run 06-munge.sh first."

# =============================================================================
# Configuration
# =============================================================================
CLUSTER_NAME="pi-cluster"
CONTROLLER_HOST="pi-node0"
COMPUTE_NODES=("pi-node1" "pi-node2" "pi-node3")
ADMIN_USER="admin"
SLURM_CONF_DIR="/etc/slurm"

log "INFO" "=== Configuring SLURM controller on ${CONTROLLER_HOST} ==="

# =============================================================================
# Create required directories
# =============================================================================
log "INFO" "Creating SLURM directories..."
install -d -m 0755 -o slurm -g slurm \
    /var/spool/slurmctld \
    /var/spool/slurmd \
    /var/log/slurm \
    "${SLURM_CONF_DIR}"

# =============================================================================
# Write slurm.conf
# =============================================================================
log "INFO" "Writing /etc/slurm/slurm.conf..."
cat > "${SLURM_CONF_DIR}/slurm.conf" << 'SLURM_CONF_EOF'
# =============================================================================
# slurm.conf — SLURM cluster configuration for pi-cluster
# Raspberry Pi 5 x4, Debian Trixie, SLURM 24.11.5
#
# IMPORTANT: This file must be IDENTICAL on all nodes.
# After any change: sudo scontrol reconfigure  (or restart slurmctld + slurmd)
# =============================================================================

# --- Cluster identity ---
ClusterName=pi-cluster
SlurmctldHost=pi-node0

# --- Authentication (MUNGE is the default and recommended method) ---
AuthType=auth/munge
CredType=cred/munge

# --- Network ports ---
SlurmctldPort=6817
SlurmdPort=6818

# --- Service accounts ---
SlurmUser=slurm
SlurmdUser=root

# --- PID files ---
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid

# --- Log files ---
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmctldDebug=info
SlurmdDebug=info

# --- State and spool directories ---
StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd

# --- Process tracking (required for cgroup resource enforcement) ---
ProctrackType=proctrack/cgroup

# --- Task plugins ---
# task/affinity: CPU pinning
# task/cgroup: memory/cpu enforcement via cgroups
TaskPlugin=task/affinity,task/cgroup

# --- Scheduler ---
SchedulerType=sched/backfill

# --- Resource selection ---
# cons_tres: Consumable TRackable RESources (cores + memory independently)
# This allows fine-grained job packing
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory

# --- Job accounting (flat file, no database required) ---
JobAcctGatherType=jobacct_gather/cgroup
AccountingStorageType=accounting_storage/none

# --- Timers ---
InactiveLimit=0
KillWait=30
MinJobAge=300
SlurmctldTimeout=120
SlurmdTimeout=300
Waittime=0

# --- Priority (simple FIFO for small cluster) ---
PriorityType=priority/basic

# --- Topology (flat network — no InfiniBand or specialized topology) ---
TopologyPlugin=topology/none

# --- Mail (disabled — no mail server) ---
# MailProg=/usr/bin/mail

# =============================================================================
# NODE DEFINITIONS
# Raspberry Pi 5: ARM Cortex-A76, 4 cores, 16 GB RAM
# RealMemory=15000: leaves ~1 GB for OS and system processes
# State=UNKNOWN: lets SLURM discover the node state on startup
# =============================================================================
NodeName=pi-node0 NodeAddr=192.168.1.101 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN Features=rpi5,headnode
NodeName=pi-node1 NodeAddr=192.168.1.102 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN Features=rpi5
NodeName=pi-node2 NodeAddr=192.168.1.103 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN Features=rpi5
NodeName=pi-node3 NodeAddr=192.168.1.104 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN Features=rpi5

# =============================================================================
# PARTITIONS
# =============================================================================

# all: all 4 nodes, default partition
# Use for: normal workloads, MPI jobs spanning all nodes
PartitionName=all Nodes=pi-node[0-3] Default=YES MaxTime=INFINITE State=UP

# compute: dedicated compute nodes only (excludes head node)
# Use for: jobs that should not compete with slurmctld overhead
PartitionName=compute Nodes=pi-node[1-3] Default=NO MaxTime=INFINITE State=UP

# debug: single node, 30-minute time limit
# Use for: interactive testing, small validation jobs
PartitionName=debug Nodes=pi-node1 Default=NO MaxTime=00:30:00 State=UP
SLURM_CONF_EOF

chown slurm:slurm "${SLURM_CONF_DIR}/slurm.conf"
chmod 0644 "${SLURM_CONF_DIR}/slurm.conf"
log "INFO" "slurm.conf written"

# =============================================================================
# Write cgroup.conf
# =============================================================================
log "INFO" "Writing /etc/slurm/cgroup.conf..."
cat > "${SLURM_CONF_DIR}/cgroup.conf" << 'CGROUP_CONF_EOF'
# =============================================================================
# cgroup.conf — SLURM cgroup plugin configuration
# Raspberry Pi 5 / Debian Trixie (cgroup v2 / unified hierarchy)
#
# NOTE: Debian Trixie uses cgroup v2 exclusively (kernel 6.12+).
#       The legacy v1 /proc/cgroups interface is not available.
#       Memory cgroup must be enabled in /boot/firmware/cmdline.txt:
#         cgroup_enable=memory
# =============================================================================

# autodetect: let SLURM determine cgroup v1 vs v2 at runtime
# This is the safest option for mixed environments
CgroupPlugin=autodetect

# Enable all available cgroup controllers in the hierarchy
# Required on systemd-managed nodes for proper CPU/memory delegation
EnableControllers=yes

# Enforce CPU core pinning (prevent jobs from running on wrong cores)
ConstrainCores=yes

# Enforce memory limits (requires cgroup_enable=memory in cmdline.txt)
ConstrainRAMSpace=yes

# Enforce swap limits
ConstrainSwapSpace=yes

# Device constraints (disabled — no GPU/specialized hardware)
ConstrainDevices=no

# Allow zero swap for jobs (completely disable swap usage for SLURM jobs)
AllowedSwapSpace=0

# Reserve 512 MB for system processes outside SLURM's control
# Jobs cannot use this memory even if requested
MemSpecLimit=512
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
mkdir -p /etc/slurm
mv /tmp/slurm.conf  /etc/slurm/slurm.conf
mv /tmp/cgroup.conf /etc/slurm/cgroup.conf
chown slurm:slurm /etc/slurm/slurm.conf /etc/slurm/cgroup.conf
chmod 0644 /etc/slurm/slurm.conf /etc/slurm/cgroup.conf
mkdir -p /var/spool/slurmd /var/log/slurm
chown slurm:slurm /var/spool/slurmd /var/log/slurm
chmod 0755 /var/spool/slurmd /var/log/slurm
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

# Quick test job
log "INFO" "Running test job (srun hostname on each node)..."
srun --nodes=1 --ntasks=1 --partition=debug hostname 2>&1 | tee -a "${LOG_FILE}" || \
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
