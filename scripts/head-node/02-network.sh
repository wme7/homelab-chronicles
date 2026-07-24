#!/usr/bin/env bash
# =============================================================================
# 02-network.sh — Head Node: Static Network Configuration
# Raspberry Pi 5 SLURM Cluster (pi-node0)
#
# Configures: static IP, hostname, /etc/hosts
# Idempotent: safe to re-run
# Run as: sudo bash 02-network.sh
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
# Configuration — edit these values for your environment
# =============================================================================
NODE_NAME="pi-node0"
NODE_IP="192.168.129.36"
NETMASK="24"
GATEWAY="192.168.128.1"
DNS_SERVERS="192.168.128.1"

# All cluster nodes (used for /etc/hosts)
declare -A CLUSTER_NODES=(
    ["pi-node0"]="192.168.129.36"
    ["pi-node1"]="192.168.129.37"
    ["pi-node2"]="192.168.129.38"
    ["pi-node3"]="192.168.129.39"
)

log "INFO" "=== Configuring network for ${NODE_NAME} ==="

# =============================================================================
# Set hostname
# =============================================================================
CURRENT_HOSTNAME="$(hostname)"
if [[ "${CURRENT_HOSTNAME}" == "${NODE_NAME}" ]]; then
    log "INFO" "Hostname already set to ${NODE_NAME} — skipping"
else
    log "INFO" "Setting hostname to ${NODE_NAME}..."
    hostnamectl set-hostname "${NODE_NAME}"
    log "INFO" "Hostname changed from '${CURRENT_HOSTNAME}' to '${NODE_NAME}'"
fi

# =============================================================================
# Configure static IP via NetworkManager (default in Raspberry Pi OS Trixie)
# =============================================================================
if ! command -v nmcli &>/dev/null; then
    die "NetworkManager (nmcli) not found. Is NetworkManager installed?"
fi

# Find the wired connection name
CONN_NAME=$(nmcli -t -f NAME,TYPE connection show | grep ethernet | head -1 | cut -d: -f1)

if [[ -z "${CONN_NAME}" ]]; then
    log "WARN" "No ethernet connection found in NetworkManager. Attempting to create one."
    IFACE=$(ip -o link show | grep -v lo | grep -v LOOPBACK | awk '{print $2}' | sed 's/://' | head -1)
    [[ -n "${IFACE}" ]] || die "No network interface found"
    nmcli connection add type ethernet ifname "${IFACE}" con-name "cluster-eth"
    CONN_NAME="cluster-eth"
fi

log "INFO" "Configuring connection '${CONN_NAME}' with static IP ${NODE_IP}/${NETMASK}..."

nmcli connection modify "${CONN_NAME}" \
    ipv4.method manual \
    ipv4.addresses "${NODE_IP}/${NETMASK}" \
    ipv4.gateway "${GATEWAY}" \
    ipv4.dns "${DNS_SERVERS}" \
    connection.autoconnect yes

nmcli connection up "${CONN_NAME}" || log "WARN" "Could not bring up connection (may already be active)"

# =============================================================================
# Write /etc/hosts
# =============================================================================
log "INFO" "Writing /etc/hosts..."
cat > /etc/hosts << HOSTS_EOF
127.0.0.1       localhost
127.0.1.1       ${NODE_NAME}

# IPv6
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters

# =============================================================================
# Raspberry Pi 5 SLURM Cluster nodes
# =============================================================================
HOSTS_EOF

for node in pi-node0 pi-node1 pi-node2 pi-node3; do
    echo "${CLUSTER_NODES[$node]}   ${node}" >> /etc/hosts
done

log "INFO" "/etc/hosts written with all cluster nodes"

# =============================================================================
# Disable cloud-init so it cannot rewrite /etc/hosts on reboot
# =============================================================================
if [[ -f /etc/cloud/cloud-init.disabled ]]; then
    log "INFO" "cloud-init already disabled — skipping"
else
    mkdir -p /etc/cloud
    touch /etc/cloud/cloud-init.disabled
    log "INFO" "Created /etc/cloud/cloud-init.disabled"
fi

# =============================================================================
# Verify connectivity
# =============================================================================
log "INFO" "Verifying network configuration..."

ASSIGNED_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep "^192\.168\." | head -1 || true)
if [[ -n "${ASSIGNED_IP}" ]]; then
    log "INFO" "Assigned IP: ${ASSIGNED_IP}"
else
    log "WARN" "No 192.168.x.x IP assigned yet — may require interface bounce or reboot"
fi

# Test gateway reachability (non-fatal)
if ping -c1 -W2 "${GATEWAY}" &>/dev/null; then
    log "INFO" "Gateway ${GATEWAY} is reachable"
else
    log "WARN" "Gateway ${GATEWAY} not reachable (non-fatal if network is not yet up)"
fi

log "INFO" "=== Network configuration complete ==="
log "INFO" "Node: ${NODE_NAME} | IP: ${NODE_IP} | Gateway: ${GATEWAY}"
log "INFO" "Next step: sudo bash 03-users.sh"
