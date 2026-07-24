#!/usr/bin/env bash
# =============================================================================
# 06-munge.sh — Head Node: MUNGE Key Generation and Distribution
# Raspberry Pi 5 SLURM Cluster (pi-node0)
#
# MUNGE provides authentication for all SLURM inter-daemon communication.
# A single cryptographic key (/etc/munge/munge.key) must be byte-identical
# on every cluster node. This script:
#   1. Generates the key on pi-node0
#   2. Sets correct permissions
#   3. Distributes the key to compute nodes via SSH
#   4. Verifies MUNGE authentication across the cluster
#
# Prerequisites: SSH key-based auth must work from pi-node0 to compute nodes.
#               (Set up by 02-network.sh / manually via ssh-keygen + ssh-copy-id)
#
# Idempotent: will NOT regenerate the key if one already exists (preserves
#             cluster state if re-run after initial setup)
# Run as: sudo bash 06-munge.sh
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
MUNGE_KEY="/etc/munge/munge.key"
COMPUTE_NODES=("pi-node1" "pi-node2" "pi-node3")
ADMIN_USER="admin"
ADMIN_KEY="/home/admin/.ssh/id_ed25519"
GENERATED_NEW_KEY=false # if true, the key will be generated and distributed to the compute nodes

log "INFO" "=== Configuring MUNGE authentication ==="

# =============================================================================
# Ensure munge directories exist with correct permissions
# =============================================================================
for dir in /etc/munge /var/lib/munge /var/log/munge /run/munge; do
    mkdir -p "${dir}"
done

chown munge:munge /etc/munge /var/lib/munge /var/log/munge
chmod 0700 /etc/munge /var/lib/munge /var/log/munge

# /run/munge is transient (recreated by systemd)
chown munge:munge /run/munge 2>/dev/null || true
chmod 0755 /run/munge 2>/dev/null || true

# =============================================================================
# Generate MUNGE key (only if it doesn't already exist)
# =============================================================================
if [[ -f "${MUNGE_KEY}" ]]; then
    log "INFO" "MUNGE key already exists at ${MUNGE_KEY} — not regenerating"
    log "INFO" "Key MD5: $(md5sum ${MUNGE_KEY} | awk '{print $1}')"
else
    log "INFO" "Generating new MUNGE key (1024 random bytes)..."
    dd if=/dev/urandom bs=1 count=1024 of="${MUNGE_KEY}" 2>/dev/null
    log "INFO" "Key generated"
    GENERATED_NEW_KEY=true
fi

# Always set correct ownership and permissions
chown munge:munge "${MUNGE_KEY}"
chmod 0400 "${MUNGE_KEY}"
log "INFO" "Permissions set: $(ls -la ${MUNGE_KEY})"

# =============================================================================
# Start MUNGE on head node
# =============================================================================
systemctl enable munge
systemctl restart munge
sleep 2

if systemctl is-active --quiet munge; then
    log "INFO" "MUNGE daemon running on pi-node0"
else
    log "ERROR" "MUNGE failed to start. Check: journalctl -u munge -n 50"
    journalctl -u munge -n 20 | tee -a "${LOG_FILE}"
    die "MUNGE startup failed"
fi

# =============================================================================
# Verify local MUNGE
# =============================================================================
log "INFO" "Testing local MUNGE encode/decode..."
MUNGE_TEST=$(munge -n | unmunge 2>&1)
echo "${MUNGE_TEST}" | tee -a "${LOG_FILE}"
echo "${MUNGE_TEST}" | grep -q "STATUS:.*Success" || die "Local MUNGE test failed"
log "INFO" "Local MUNGE test: PASSED"

# =============================================================================
# Distribute MUNGE key to compute nodes
# =============================================================================
KEY_MD5=$(md5sum "${MUNGE_KEY}" | awk '{print $1}')
log "INFO" "Distributing MUNGE key (MD5: ${KEY_MD5}) to compute nodes..."

if [[ "${GENERATED_NEW_KEY}" == true ]]; then
    for node in "${COMPUTE_NODES[@]}"; do
        log "INFO" "Processing ${node}..."

        # Test SSH connectivity
        if ! ssh -i "${ADMIN_KEY}" -o ConnectTimeout=5 -o BatchMode=yes "${ADMIN_USER}@${node}" true 2>/dev/null; then
            log "WARN" "Cannot SSH to ${node} — skipping. Configure SSH first, then re-run."
            continue
        fi

        # Copy key
        scp -i "${ADMIN_KEY}" -q "${MUNGE_KEY}" "${ADMIN_USER}@${node}:/tmp/munge.key.new"

        # Install key with correct permissions on remote node
        ssh -i "${ADMIN_KEY}" "${ADMIN_USER}@${node}" "sudo bash -s" << 'REMOTE_EOF'
set -euo pipefail
mkdir -p /etc/munge /var/lib/munge /var/log/munge /run/munge
mv /tmp/munge.key.new /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
chmod 0400 /etc/munge/munge.key
chown munge:munge /etc/munge /var/lib/munge /var/log/munge
chmod 0700 /etc/munge /var/lib/munge /var/log/munge
chown munge:munge /run/munge 2>/dev/null || true
chmod 0755 /run/munge 2>/dev/null || true
systemctl enable munge
systemctl restart munge
REMOTE_EOF

        log "INFO" "MUNGE key installed and daemon started on ${node}"

        # Verify remote MUNGE
        sleep 2
        log "INFO" "Testing MUNGE from pi-node0 -> ${node}..."
        REMOTE_TEST=$(munge -n | ssh -i "${ADMIN_KEY}" "${ADMIN_USER}@${node}" "sudo unmunge" 2>&1 || true)
        log "INFO" "  ${node}: ${REMOTE_TEST}"
        if echo "${REMOTE_TEST}" | grep -q "STATUS:.*Success"; then
            log "INFO" "  Cross-node MUNGE test to ${node}: PASSED"
        else
            log "WARN" "  Cross-node MUNGE test to ${node}: FAILED — check munge UID and key"
        fi
    done
fi

# =============================================================================
# Final verification — compare key MD5 across all nodes
# =============================================================================
log "INFO" "=== MUNGE key consistency check ==="
log "INFO" "pi-node0 key MD5: ${KEY_MD5}"

for node in "${COMPUTE_NODES[@]}"; do
    REMOTE_MD5=$(ssh -i "${ADMIN_KEY}" -o BatchMode=yes "${ADMIN_USER}@${node}" "sudo md5sum /etc/munge/munge.key 2>/dev/null | awk '{print \$1}'" 2>/dev/null || echo "UNREACHABLE")
    if [[ "${REMOTE_MD5}" == "${KEY_MD5}" ]]; then
        log "INFO" "${node} key MD5: ${REMOTE_MD5} ✓ MATCH"
    else
        log "WARN" "${node} key MD5: ${REMOTE_MD5} ✗ MISMATCH (expected ${KEY_MD5})"
    fi
done

log "INFO" "=== MUNGE configuration complete ==="
log "INFO" "Next step: sudo bash 07-slurm-controller.sh"
