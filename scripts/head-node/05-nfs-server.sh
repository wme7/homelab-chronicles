#!/usr/bin/env bash
# =============================================================================
# 05-nfs-server.sh — Head Node: NFS Server Setup
# Raspberry Pi 5 SLURM Cluster (pi-node0)
#
# Mounts the 1 TB USB SSD at /mnt/storage and exports:
#   /mnt/storage/shared      → /shared   (all nodes, rw)
#   /mnt/storage/home/user   → /home/user (all nodes, rw)
#
# Also bind-mounts those directories to /shared and /home/user on pi-node0
# so pathnames match compute nodes (pi-node0 participates as a compute node).
#
# The script locates the USB SSD by size (>= 900 GB), formats it if needed,
# and adds a persistent fstab entry by UUID.
#
# Idempotent: safe to re-run (will not reformat an already-mounted drive)
# Run as: sudo bash 05-nfs-server.sh
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
STORAGE_MOUNT="/mnt/storage"
SHARED_DIR="${STORAGE_MOUNT}/shared"
USER_HOME_DIR="${STORAGE_MOUNT}/home/user"
LOCAL_SHARED="/shared"
LOCAL_USER_HOME="/home/user"
BIND_FSTAB_MARKER="# pi-cluster bind mounts"
NFS_SUBNET="192.168.129.0/24"
CLUSTER_USER="user"
CLUSTER_USER_UID=1002

log "INFO" "=== Setting up NFS server ==="

# =============================================================================
# Locate the USB SSD
# =============================================================================
log "INFO" "Scanning block devices for USB SSD (looking for device >= 900 GB)..."
lsblk -o NAME,SIZE,TYPE,TRAN | tee -a "${LOG_FILE}"

USB_DISK=""
while IFS= read -r line; do
    name=$(echo "${line}" | awk '{print $1}')
    size=$(echo "${line}" | awk '{print $2}')
    type=$(echo "${line}" | awk '{print $3}')
    tran=$(echo "${line}" | awk '{print $4}')

    if [[ "${type}" == "disk" && "${tran}" == "usb" ]]; then
        # Verify it's large enough (>= 900G)
        size_gb=$(lsblk -bnd -o SIZE "/dev/${name}" 2>/dev/null | awk '{printf "%d", $1/1073741824}')
        if [[ "${size_gb}" -ge 900 ]]; then
            USB_DISK="/dev/${name}"
            log "INFO" "Found USB SSD: ${USB_DISK} (${size_gb} GB)"
            break
        fi
    fi
done < <(lsblk -o NAME,SIZE,TYPE,TRAN -n)

if [[ -z "${USB_DISK}" ]]; then
    die "No USB SSD >= 900 GB found. Connect the USB SSD and retry. Available devices:\n$(lsblk)"
fi

# =============================================================================
# Check if already mounted
# =============================================================================
if mountpoint -q "${STORAGE_MOUNT}"; then
    log "INFO" "${STORAGE_MOUNT} is already mounted — skipping format/mount"
else
    # Check if partition exists
    USB_PART="${USB_DISK}1"
    if ! lsblk "${USB_PART}" &>/dev/null; then
        log "INFO" "No partition found on ${USB_DISK}. Creating GPT partition table and ext4 partition..."
        log "WARN" "THIS WILL ERASE ALL DATA ON ${USB_DISK}"
        sleep 5   # Brief pause to allow interruption

        parted "${USB_DISK}" --script mklabel gpt
        parted "${USB_DISK}" --script mkpart primary ext4 0% 100%
        partprobe "${USB_DISK}"
        sleep 2

        log "INFO" "Formatting ${USB_PART} as ext4 with label 'cluster-storage'..."
        mkfs.ext4 -L "cluster-storage" "${USB_PART}"
        log "INFO" "Format complete"
    else
        # Partition exists — check if it has a filesystem
        FS_TYPE=$(blkid -s TYPE -o value "${USB_PART}" 2>/dev/null || echo "")
        if [[ -z "${FS_TYPE}" ]]; then
            log "INFO" "Partition ${USB_PART} has no filesystem. Formatting as ext4..."
            mkfs.ext4 -L "cluster-storage" "${USB_PART}"
        else
            log "INFO" "Partition ${USB_PART} already has filesystem: ${FS_TYPE}"
            # Add label if not already set
            if ! blkid -s LABEL -o value "${USB_PART}" | grep -q "cluster-storage"; then
                e2label "${USB_PART}" "cluster-storage" 2>/dev/null || true
            fi
        fi
    fi

    # Get UUID for stable fstab entry
    USB_UUID=$(blkid -s UUID -o value "${USB_PART}")
    [[ -n "${USB_UUID}" ]] || die "Could not determine UUID for ${USB_PART}"

    # Create mount point
    mkdir -p "${STORAGE_MOUNT}"

    # Add to fstab if not already present
    if grep -q "${USB_UUID}" /etc/fstab; then
        log "INFO" "fstab entry for UUID=${USB_UUID} already exists"
    else
        log "INFO" "Adding fstab entry for ${STORAGE_MOUNT} (UUID=${USB_UUID})"
        echo "UUID=${USB_UUID}  ${STORAGE_MOUNT}  ext4  defaults,noatime  0  2" >> /etc/fstab
    fi

    systemctl daemon-reload
    mount "${STORAGE_MOUNT}"
    log "INFO" "Mounted ${STORAGE_MOUNT}"
fi

# =============================================================================
# Create directory structure on the USB SSD
# =============================================================================
log "INFO" "Creating shared directory structure..."

mkdir -p "${SHARED_DIR}"
mkdir -p "${USER_HOME_DIR}"

# Set ownership of user home
chown -R "${CLUSTER_USER}:${CLUSTER_USER}" "${USER_HOME_DIR}" 2>/dev/null || \
    chown -R "${CLUSTER_USER_UID}:${CLUSTER_USER_UID}" "${USER_HOME_DIR}"

chmod 755 "${SHARED_DIR}"
chmod 750 "${USER_HOME_DIR}"

log "INFO" "Directory structure:"
ls -la "${STORAGE_MOUNT}/"
ls -la "${STORAGE_MOUNT}/home/" 2>/dev/null || true

# =============================================================================
# Bind-mount SSD paths to /shared and /home/user (head-as-compute path parity)
# =============================================================================
log "INFO" "Configuring bind mounts for ${LOCAL_SHARED} and ${LOCAL_USER_HOME}..."

mkdir -p "${LOCAL_SHARED}"
mkdir -p "${LOCAL_USER_HOME}"

if grep -q "${BIND_FSTAB_MARKER}" /etc/fstab; then
    log "INFO" "Bind mount fstab entries already exist — skipping"
else
    log "INFO" "Adding bind mount entries to /etc/fstab..."
    cat >> /etc/fstab << FSTAB_EOF

${BIND_FSTAB_MARKER}
${SHARED_DIR}      ${LOCAL_SHARED}     none  bind,x-systemd.requires-mounts-for=${STORAGE_MOUNT}  0  0
${USER_HOME_DIR}   ${LOCAL_USER_HOME}  none  bind,x-systemd.requires-mounts-for=${STORAGE_MOUNT}  0  0
FSTAB_EOF
    log "INFO" "fstab bind mounts updated"
fi

systemctl daemon-reload

for mount_point in "${LOCAL_SHARED}" "${LOCAL_USER_HOME}"; do
    if mountpoint -q "${mount_point}"; then
        log "INFO" "${mount_point} is already mounted"
    else
        if mount "${mount_point}"; then
            log "INFO" "Bind-mounted ${mount_point}"
        else
            die "Failed to bind-mount ${mount_point}"
        fi
    fi
done

# =============================================================================
# Configure NFS exports
# =============================================================================
log "INFO" "Configuring NFS exports..."

EXPORTS_FILE="/etc/exports"
EXPORTS_MARKER="# pi-cluster NFS exports"

if grep -q "${EXPORTS_MARKER}" "${EXPORTS_FILE}"; then
    log "INFO" "NFS exports already configured — skipping"
else
    cat >> "${EXPORTS_FILE}" << EXPORTS_EOF

${EXPORTS_MARKER}
${SHARED_DIR}      ${NFS_SUBNET}(rw,sync,no_subtree_check,no_root_squash)
${USER_HOME_DIR}   ${NFS_SUBNET}(rw,sync,no_subtree_check,no_root_squash)
EXPORTS_EOF
    log "INFO" "NFS exports added to ${EXPORTS_FILE}"
fi

# =============================================================================
# Enable and start NFS server
# =============================================================================
systemctl enable nfs-kernel-server
systemctl restart nfs-kernel-server
log "INFO" "NFS server started"

# Apply exports
exportfs -ra
log "INFO" "Exports applied"

# =============================================================================
# Verification
# =============================================================================
log "INFO" "Active NFS exports:"
exportfs -v 2>&1 | tee -a "${LOG_FILE}"

log "INFO" "Storage usage:"
df -h "${STORAGE_MOUNT}" | tee -a "${LOG_FILE}"

log "INFO" "=== NFS server setup complete ==="
log "INFO" "Exports: ${SHARED_DIR} and ${USER_HOME_DIR}"
log "INFO" "Head-node bind mounts: ${LOCAL_SHARED} and ${LOCAL_USER_HOME}"
log "INFO" "Clients should mount using:"
log "INFO" "  pi-node0:${SHARED_DIR} /shared nfs defaults,_netdev,soft,timeo=30,retrans=3 0 0"
log "INFO" "  pi-node0:${USER_HOME_DIR} /home/user nfs defaults,_netdev,soft,timeo=30,retrans=3 0 0"
log "INFO" "Next step: sudo bash 06-munge.sh"
