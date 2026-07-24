#!/usr/bin/env bash
# =============================================================================
# 01-base-system.sh — Compute Node: Base System Configuration
# Raspberry Pi 5 SLURM Cluster (pi-node1 / pi-node2 / pi-node3)
#
# Identical to head node base setup, but installs slurmd only (not slurmctld).
#
# Idempotent: safe to re-run
# Run as: sudo bash 01-base-system.sh
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

ARCH=$(uname -m)
[[ "${ARCH}" == "aarch64" ]] || die "Expected aarch64 architecture, got ${ARCH}"

log "INFO" "=== Starting base system configuration for COMPUTE NODE $(hostname) ==="

# =============================================================================
# Memory cgroup (NOT required for current live config)
# Live cluster uses CgroupPlugin=disabled / proctrack/linuxproc.
# Leave cgroup_enable=memory out of cmdline.txt unless you later enable
# cgroup job isolation (see documents/guide.md Future Improvements).
# =============================================================================
# CMDLINE_FILE="/boot/firmware/cmdline.txt"
# [[ -f "${CMDLINE_FILE}" ]] || die "Cannot find ${CMDLINE_FILE}"

# if grep -q "cgroup_enable=memory" "${CMDLINE_FILE}"; then
#     log "INFO" "cgroup_enable=memory already set — skipping"
# else
#     log "INFO" "Adding cgroup_enable=memory to ${CMDLINE_FILE}"
#     sed -i 's/$/ cgroup_enable=memory/' "${CMDLINE_FILE}"
# fi

# =============================================================================
# PCIe and NVMe configuration
# =============================================================================
CONFIG_FILE="/boot/firmware/config.txt"
[[ -f "${CONFIG_FILE}" ]] || die "Cannot find ${CONFIG_FILE}"

if grep -q "dtparam=pciex1" "${CONFIG_FILE}"; then
    log "INFO" "PCIe already configured in ${CONFIG_FILE} — skipping"
else
    cat >> "${CONFIG_FILE}" << 'CONF_EOF'

# =============================================================================
# Pi Cluster configuration — added by 01-base-system.sh
# =============================================================================
dtparam=pciex1
dtparam=pciex1_gen=3
dtoverlay=disable-bt
dtoverlay=disable-wifi
CONF_EOF
fi

# =============================================================================
# Update and install packages
# =============================================================================
log "INFO" "Updating package lists..."
apt-get update -qq

log "INFO" "Upgrading installed packages..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

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
    net-tools \
    dnsutils \
    lsof \
    sysstat \
    nvme-cli \
    stress-ng \
    openssh-server \
    rsync

log "INFO" "Installing SLURM compute node packages and PMIx (MpiDefault=pmix)..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    slurmd \
    slurm-client \
    libpmix-dev

# =============================================================================
# Update EEPROM
# =============================================================================
if command -v rpi-eeprom-update &>/dev/null; then
    log "INFO" "Checking EEPROM firmware..."
    rpi-eeprom-update -a 2>&1 | tee -a "${LOG_FILE}" || log "WARN" "EEPROM check failed (non-fatal)"
fi

# =============================================================================
# Disable unneeded services
# =============================================================================
for svc in bluetooth hciuart wpa_supplicant; do
    systemctl disable --now "${svc}" 2>/dev/null || true
done

# =============================================================================
# SLURM compute directories
# =============================================================================
log "INFO" "Creating SLURM directories..."
install -d -m 0755 -o slurm -g slurm \
    /var/spool/slurmd \
    /var/log/slurm

# =============================================================================
# System limits
# =============================================================================
LIMITS_FILE="/etc/security/limits.d/slurm.conf"
if [[ ! -f "${LIMITS_FILE}" ]]; then
    cat > "${LIMITS_FILE}" << 'LIMITS_EOF'
*    soft nofile  65536
*    hard nofile  65536
*    soft nproc   unlimited
*    hard nproc   unlimited
LIMITS_EOF
fi

log "INFO" "=== Base system configuration complete for $(hostname) ==="
log "INFO" "Next step: sudo bash 02-network.sh"
