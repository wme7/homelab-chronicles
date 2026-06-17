#!/usr/bin/env bash
# =============================================================================
# 03-users.sh — Head Node: User Account Creation
# Raspberry Pi 5 SLURM Cluster (pi-node0)
#
# Creates: munge (UID 64003), slurm (UID 64002), user (UID 2000)
# CRITICAL: munge and slurm UIDs must be IDENTICAL across ALL cluster nodes.
#           Run this script on every node BEFORE installing munge/slurm packages.
#           If packages are already installed, this script still checks consistency.
#
# Idempotent: safe to re-run
# Run as: sudo bash 03-users.sh
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
# Configuration — these UIDs/GIDs must match on ALL cluster nodes
# =============================================================================
MUNGE_UID=64003
MUNGE_GID=64003
SLURM_UID=64002
SLURM_GID=64002
USER_UID=2000
USER_GID=2000
USER_NAME="user"
ADMIN_NAME="admin"

log "INFO" "=== Creating cluster user accounts ==="

# Helper: create a system group if it does not exist with a specific GID
ensure_group() {
    local gname="$1" gid="$2"
    if getent group "${gname}" &>/dev/null; then
        local existing_gid
        existing_gid=$(getent group "${gname}" | cut -d: -f3)
        if [[ "${existing_gid}" != "${gid}" ]]; then
            die "Group '${gname}' exists with GID ${existing_gid} but expected GID ${gid}. Fix manually."
        fi
        log "INFO" "Group '${gname}' (GID ${gid}) already exists — skipping"
    else
        groupadd --gid "${gid}" "${gname}"
        log "INFO" "Created group '${gname}' with GID ${gid}"
    fi
}

# Helper: create a system user if it does not exist
ensure_system_user() {
    local uname="$1" uid="$2" gid="$3"
    if id "${uname}" &>/dev/null; then
        local existing_uid
        existing_uid=$(id -u "${uname}")
        if [[ "${existing_uid}" != "${uid}" ]]; then
            die "User '${uname}' exists with UID ${existing_uid} but expected UID ${uid}. Fix manually."
        fi
        log "INFO" "User '${uname}' (UID ${uid}) already exists — skipping"
    else
        useradd --uid "${uid}" --gid "${gid}" \
            --no-create-home \
            --shell /usr/sbin/nologin \
            --system \
            "${uname}"
        log "INFO" "Created system user '${uname}' with UID ${uid}"
    fi
}

# =============================================================================
# munge system user
# =============================================================================
ensure_group "munge" "${MUNGE_GID}"
ensure_system_user "munge" "${MUNGE_UID}" "${MUNGE_GID}"

# =============================================================================
# slurm system user
# =============================================================================
ensure_group "slurm" "${SLURM_GID}"
ensure_system_user "slurm" "${SLURM_UID}" "${SLURM_GID}"

# =============================================================================
# Standard user account (for SLURM job execution)
# =============================================================================
if id "${USER_NAME}" &>/dev/null; then
    log "INFO" "User '${USER_NAME}' already exists — skipping"
else
    if ! getent group "${USER_NAME}" &>/dev/null; then
        groupadd --gid "${USER_GID}" "${USER_NAME}"
    fi
    useradd --uid "${USER_UID}" \
            --gid "${USER_GID}" \
            --create-home \
            --shell /bin/bash \
            --comment "SLURM job execution user" \
            "${USER_NAME}"
    log "INFO" "Created user '${USER_NAME}' with UID ${USER_UID}"
    log "WARN" "Set a password for '${USER_NAME}': sudo passwd ${USER_NAME}"
fi

# =============================================================================
# Admin user (verify it exists with sudo access)
# =============================================================================
if id "${ADMIN_NAME}" &>/dev/null; then
    log "INFO" "Admin user '${ADMIN_NAME}' exists"
    if groups "${ADMIN_NAME}" | grep -q "sudo"; then
        log "INFO" "User '${ADMIN_NAME}' already has sudo privileges"
    else
        usermod -aG sudo "${ADMIN_NAME}"
        log "INFO" "Added '${ADMIN_NAME}' to sudo group"
    fi
else
    log "WARN" "Admin user '${ADMIN_NAME}' not found — it should have been created during OS installation"
    log "WARN" "Creating admin user now (no password set — set one manually)"
    useradd --create-home --shell /bin/bash --groups sudo "${ADMIN_NAME}"
    log "INFO" "Run: sudo passwd admin"
fi

# =============================================================================
# Summary
# =============================================================================
log "INFO" "=== User account summary ==="
for u in munge slurm "${USER_NAME}" "${ADMIN_NAME}"; do
    if id "${u}" &>/dev/null; then
        log "INFO" "  $(id "${u}")"
    fi
done

log "INFO" "=== User creation complete ==="
log "INFO" "Next step: sudo bash 04-chrony.sh"
