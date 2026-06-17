#!/usr/bin/env bash
# =============================================================================
# 05-nfs-client.sh — Compute Node: NFS Client Mount Setup
# Raspberry Pi 5 SLURM Cluster (pi-node1 / pi-node2 / pi-node3)
#
# Mounts NFS shares from pi-node0:
#   pi-node0:/mnt/storage/shared      → /shared
#   pi-node0:/mnt/storage/home/user   → /home/user
#
# Uses _netdev option to defer mount until network is up.
# Uses soft mount with timeout to prevent indefinite hangs if NFS server is down.
#
# Idempotent: safe to re-run
# Run as: sudo bash 05-nfs-client.sh
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

# =============================================================================
# Configuration
# =============================================================================
NFS_SERVER="pi-node0"
NFS_SHARED="${NFS_SERVER}:/mnt/storage/shared"
NFS_USER_HOME="${NFS_SERVER}:/mnt/storage/home/user"
LOCAL_SHARED="/shared"
LOCAL_USER_HOME="/home/user"

# NFS mount options:
# _netdev: wait for network before mounting at boot
# soft:    return error after timeout instead of hanging forever
# timeo=30: 3-second timeout units (30 = 30 * 0.1s = 3s initial timeout)
# retrans=3: retry 3 times before returning error
NFS_OPTS="nfs  defaults,_netdev,soft,timeo=30,retrans=3  0  0"

log "INFO" "=== Setting up NFS client mounts on $(hostname) ==="

# =============================================================================
# Verify NFS server is reachable
# =============================================================================
if ! ping -c1 -W3 "${NFS_SERVER}" &>/dev/null; then
    log "WARN" "Cannot ping ${NFS_SERVER} — NFS mounts may fail. Continuing anyway."
fi

if ! showmount -e "${NFS_SERVER}" &>/dev/null; then
    log "WARN" "Cannot reach NFS server exports on ${NFS_SERVER}."
    log "WARN" "Ensure pi-node0 05-nfs-server.sh has been run first."
fi

# =============================================================================
# Create mount points
# =============================================================================
mkdir -p "${LOCAL_SHARED}"
mkdir -p "${LOCAL_USER_HOME}"

# =============================================================================
# Add fstab entries
# =============================================================================
FSTAB_MARKER="# pi-cluster NFS mounts"

if grep -q "${FSTAB_MARKER}" /etc/fstab; then
    log "INFO" "NFS fstab entries already exist — skipping"
else
    log "INFO" "Adding NFS entries to /etc/fstab..."
    cat >> /etc/fstab << FSTAB_EOF

${FSTAB_MARKER}
${NFS_SHARED}     ${LOCAL_SHARED}     ${NFS_OPTS}
${NFS_USER_HOME}  ${LOCAL_USER_HOME}  ${NFS_OPTS}
FSTAB_EOF
    log "INFO" "fstab updated"
fi

systemctl daemon-reload

# =============================================================================
# Mount the NFS shares
# =============================================================================
log "INFO" "Mounting NFS shares..."

for mount_point in "${LOCAL_SHARED}" "${LOCAL_USER_HOME}"; do
    if mountpoint -q "${mount_point}"; then
        log "INFO" "${mount_point} is already mounted"
    else
        if mount "${mount_point}" 2>/dev/null; then
            log "INFO" "Mounted ${mount_point}"
        else
            log "WARN" "Failed to mount ${mount_point} — NFS server may not be ready"
            log "WARN" "Run: sudo mount ${mount_point}  (after ensuring pi-node0 NFS is running)"
        fi
    fi
done

# =============================================================================
# Verification
# =============================================================================
log "INFO" "NFS mount status:"
df -h | grep -E "nfs|shared|user" | tee -a "${LOG_FILE}" || \
    log "WARN" "No NFS mounts visible in df output"

mount | grep nfs | tee -a "${LOG_FILE}" || log "WARN" "No NFS mounts in mount table"

# Write test
if mountpoint -q "${LOCAL_SHARED}"; then
    TEST_FILE="${LOCAL_SHARED}/nfs-write-test-$(hostname)"
    if touch "${TEST_FILE}" 2>/dev/null; then
        log "INFO" "NFS write test to ${LOCAL_SHARED}: PASSED"
        rm -f "${TEST_FILE}"
    else
        log "WARN" "NFS write test to ${LOCAL_SHARED}: FAILED (permission issue?)"
    fi
fi

log "INFO" "=== NFS client setup complete on $(hostname) ==="
log "INFO" "Next step: sudo bash 06-munge.sh"
