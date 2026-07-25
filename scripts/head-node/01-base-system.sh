#!/usr/bin/env bash
# =============================================================================
# 01-base-system.sh — Head Node: Base System Configuration
# Raspberry Pi 5 SLURM Cluster (pi-node0)
#
# Idempotent: safe to re-run
# Prerequisites: Raspberry Pi OS Lite 64-bit (Debian Trixie), booted from NVMe
# Run as: sudo bash 01-base-system.sh
# =============================================================================
set -euo pipefail

LOG_FILE="/var/log/pi-cluster-setup.log"
SCRIPT_NAME="$(basename "$0")"

log() {
    local level="$1"; shift
    local msg="$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] [${SCRIPT_NAME}] ${msg}" | tee -a "${LOG_FILE}"
}

die() {
    log "ERROR" "$*"
    exit 1
}

# =============================================================================
# Prerequisite checks
# =============================================================================
[[ "$(id -u)" -eq 0 ]] || die "This script must be run as root (sudo)"

ARCH=$(uname -m)
[[ "${ARCH}" == "aarch64" ]] || die "Expected aarch64 architecture, got ${ARCH}"

log "INFO" "=== Starting base system configuration for HEAD NODE ==="

# =============================================================================
# Memory cgroup (NOT required for current live config)
# Live cluster uses CgroupPlugin=disabled / proctrack/linuxproc.
# Leave cgroup_enable=memory out of cmdline.txt unless you later enable
# cgroup job isolation (see documents/guide.md Future Improvements).
# =============================================================================
# CMDLINE_FILE="/boot/firmware/cmdline.txt"

# if [[ ! -f "${CMDLINE_FILE}" ]]; then
#     die "Cannot find ${CMDLINE_FILE}. Is this a Raspberry Pi OS installation?"
# fi

# if grep -q "cgroup_enable=memory" "${CMDLINE_FILE}"; then
#     log "INFO" "cgroup_enable=memory already set in ${CMDLINE_FILE} — skipping"
# else
#     log "INFO" "Adding cgroup_enable=memory to ${CMDLINE_FILE}"
#     # cmdline.txt is a single line; append the option
#     sed -i 's/$/ cgroup_enable=memory/' "${CMDLINE_FILE}"
#     log "INFO" "cmdline.txt updated — reboot required before SLURM starts"
# fi

# =============================================================================
# PCIe and NVMe configuration in config.txt
# =============================================================================
CONFIG_FILE="/boot/firmware/config.txt"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    die "Cannot find ${CONFIG_FILE}"
fi

if grep -q "dtparam=pciex1" "${CONFIG_FILE}"; then
    log "INFO" "PCIe already enabled in ${CONFIG_FILE} — skipping"
else
    log "INFO" "Enabling PCIe in ${CONFIG_FILE}"
    cat >> "${CONFIG_FILE}" << 'CONF_EOF'

# =============================================================================
# Pi Cluster configuration — added by 01-base-system.sh
# =============================================================================

# Enable PCIe FFC interface (required for third-party M.2 HATs)
dtparam=pciex1

# Enable PCIe Gen 3 speed (unofficial but stable with Transcend 256GB NVMe)
dtparam=pciex1_gen=3

# Disable Bluetooth and Wi-Fi (cluster uses wired networking only)
dtoverlay=disable-bt
dtoverlay=disable-wifi
CONF_EOF
fi

# =============================================================================
# Update package lists and upgrade existing packages
# =============================================================================
log "INFO" "Updating package lists..."
apt-get update -qq

log "INFO" "Upgrading installed packages..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

# =============================================================================
# Install required packages
# =============================================================================
log "INFO" "Installing base packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    vim \
    curl \
    wget \
    git \
    htop \
    iotop \
    nload \
    tmux \
    chrony \
    munge \
    libmunge-dev \
    nfs-common \
    nfs-kernel-server \
    net-tools \
    dnsutils \
    lsof \
    sysstat \
    nvme-cli \
    stress-ng \
    openssh-server \
    rsync \
    parted \
    e2fsprogs \
    util-linux

log "INFO" "Installing SLURM packages and PMIx (MpiDefault=pmix)..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    slurm-wlm \
    libpmix-dev

# =============================================================================
# Update EEPROM firmware (non-blocking — applies on next reboot)
# =============================================================================
if command -v rpi-eeprom-update &>/dev/null; then
    log "INFO" "Checking EEPROM firmware..."
    rpi-eeprom-update -a 2>&1 | tee -a "${LOG_FILE}" || log "WARN" "EEPROM update check failed (non-fatal)"
else
    log "WARN" "rpi-eeprom-update not found — skipping EEPROM update"
fi

# =============================================================================
# Disable unneeded services
# =============================================================================
log "INFO" "Disabling unnecessary services..."

for svc in bluetooth hciuart wpa_supplicant; do
    if systemctl list-unit-files "${svc}.service" &>/dev/null; then
        systemctl disable --now "${svc}" 2>/dev/null || true
        log "INFO" "Disabled: ${svc}"
    fi
done

# =============================================================================
# Create SLURM required directories
# =============================================================================
log "INFO" "Creating SLURM directories..."

install -d -m 0755 -o slurm -g slurm \
    /var/spool/slurm/ctld \
    /var/spool/slurm/d \
    /var/log/slurm

# =============================================================================
# System limits for SLURM
# =============================================================================
LIMITS_FILE="/etc/security/limits.d/slurm.conf"
if [[ ! -f "${LIMITS_FILE}" ]]; then
    log "INFO" "Setting system limits for SLURM..."
    cat > "${LIMITS_FILE}" << 'LIMITS_EOF'
# SLURM job resource limits
*    soft nofile  65536
*    hard nofile  65536
*    soft nproc   unlimited
*    hard nproc   unlimited
LIMITS_EOF
fi

log "INFO" "=== Base system configuration complete ==="
log "INFO" "Next step: sudo bash 02-network.sh"
