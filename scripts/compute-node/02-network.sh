#!/usr/bin/env bash
# =============================================================================
# 02-network.sh — Compute Node: Static Network Configuration
# Raspberry Pi 5 SLURM Cluster (pi-node1 / pi-node2 / pi-node3)
#
# IMPORTANT: Edit NODE_NAME and NODE_IP below before running on each node.
#
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
# Configuration — EDIT THESE FOR EACH NODE
# =============================================================================
# Detect which node this is based on current hostname (if already set)
# or set manually:
#   NODE_NAME="pi-node1"
#   NODE_IP="192.168.1.102"

CURRENT_HOSTNAME="$(hostname)"
case "${CURRENT_HOSTNAME}" in
    pi-node1) NODE_NAME="pi-node1"; NODE_IP="192.168.1.102" ;;
    pi-node2) NODE_NAME="pi-node2"; NODE_IP="192.168.1.103" ;;
    pi-node3) NODE_NAME="pi-node3"; NODE_IP="192.168.1.104" ;;
    *)
        # Auto-detection failed — must set manually
        log "WARN" "Cannot auto-detect node identity from hostname '${CURRENT_HOSTNAME}'"
        log "WARN" "Edit NODE_NAME and NODE_IP variables in this script, then re-run."
        die "Set NODE_NAME and NODE_IP manually"
        ;;
esac

NETMASK="24"
GATEWAY="192.168.1.1"
DNS_SERVERS="8.8.8.8,8.8.4.4"

declare -A CLUSTER_NODES=(
    ["pi-node0"]="192.168.1.101"
    ["pi-node1"]="192.168.1.102"
    ["pi-node2"]="192.168.1.103"
    ["pi-node3"]="192.168.1.104"
)

log "INFO" "=== Configuring network for compute node ${NODE_NAME} (${NODE_IP}) ==="

# =============================================================================
# Set hostname
# =============================================================================
if [[ "$(hostname)" == "${NODE_NAME}" ]]; then
    log "INFO" "Hostname already ${NODE_NAME} — skipping"
else
    hostnamectl set-hostname "${NODE_NAME}"
    log "INFO" "Hostname set to ${NODE_NAME}"
fi

# =============================================================================
# Configure static IP
# =============================================================================
command -v nmcli &>/dev/null || die "NetworkManager not found"

CONN_NAME=$(nmcli -t -f NAME,TYPE connection show | grep ethernet | head -1 | cut -d: -f1)

if [[ -z "${CONN_NAME}" ]]; then
    IFACE=$(ip -o link show | grep -v lo | grep -v LOOPBACK | awk '{print $2}' | sed 's/://' | head -1)
    nmcli connection add type ethernet ifname "${IFACE}" con-name "cluster-eth"
    CONN_NAME="cluster-eth"
fi

nmcli connection modify "${CONN_NAME}" \
    ipv4.method manual \
    ipv4.addresses "${NODE_IP}/${NETMASK}" \
    ipv4.gateway "${GATEWAY}" \
    ipv4.dns "${DNS_SERVERS}" \
    connection.autoconnect yes

nmcli connection up "${CONN_NAME}" || true

# =============================================================================
# Write /etc/hosts
# =============================================================================
cat > /etc/hosts << HOSTS_EOF
127.0.0.1       localhost
127.0.1.1       ${NODE_NAME}

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

log "INFO" "/etc/hosts written"

# Verify head node reachability
if ping -c1 -W3 pi-node0 &>/dev/null; then
    log "INFO" "Head node pi-node0 is reachable"
else
    log "WARN" "Cannot ping pi-node0 — check network or head node status"
fi

log "INFO" "=== Network configuration complete for ${NODE_NAME} ==="
log "INFO" "Next step: sudo bash 03-users.sh"
