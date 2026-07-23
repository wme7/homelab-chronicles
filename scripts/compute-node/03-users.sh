#!/usr/bin/env bash
# =============================================================================
# 03-users.sh — Compute Node: User Account Creation
# Raspberry Pi 5 SLURM Cluster (pi-node1 / pi-node2 / pi-node3)
#
# Creates: munge (UID 900), slurm (UID 901), user (UID 1002), admin (UID 1000)
# Same UID/GID map as head-node/03-users.sh; user home is NFS (no local home).
# CRITICAL: these UIDs/GIDs must be IDENTICAL across ALL cluster nodes.
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
MUNGE_UID=900
MUNGE_GID=900
SLURM_UID=901
SLURM_GID=901
USER_UID=1002
USER_GID=1002
USER_NAME="user"
ADMIN_UID=1000
ADMIN_GID=1000
ADMIN_NAME="admin"

log "INFO" "=== Creating cluster user accounts on $(hostname) ==="

# Helper: create a system group if it does not exist with a specific GID
ensure_group() {
    local gname="$1" gid="$2"
    if getent group "${gname}" &>/dev/null; then
        local existing_gid
        existing_gid=$(getent group "${gname}" | cut -d: -f3)
        [[ "${existing_gid}" == "${gid}" ]] || \
            die "Group '${gname}' exists with GID ${existing_gid} but expected GID ${gid}. Fix manually."
        log "INFO" "Group '${gname}' (GID ${gid}) already exists — skipping"
    else
        groupadd --gid "${gid}" "${gname}"
        log "INFO" "Created group '${gname}' with GID ${gid}"
    fi
}

# Helper: assert an existing user has the expected UID and primary GID
assert_user_ids() {
    local uname="$1" uid="$2" gid="$3"
    local existing_uid existing_gid
    existing_uid=$(id -u "${uname}")
    existing_gid=$(id -g "${uname}")
    [[ "${existing_uid}" == "${uid}" ]] || \
        die "User '${uname}' exists with UID ${existing_uid} but expected UID ${uid}. Fix manually."
    [[ "${existing_gid}" == "${gid}" ]] || \
        die "User '${uname}' exists with GID ${existing_gid} but expected GID ${gid}. Fix manually."
}

# Helper: create a system user if it does not exist
ensure_system_user() {
    local uname="$1" uid="$2" gid="$3"
    if id "${uname}" &>/dev/null; then
        assert_user_ids "${uname}" "${uid}" "${gid}"
        log "INFO" "User '${uname}' (UID ${uid}, GID ${gid}) already exists — skipping"
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
# Standard user account (for SLURM job execution; home on NFS)
# =============================================================================
ensure_group "${USER_NAME}" "${USER_GID}"
if id "${USER_NAME}" &>/dev/null; then
    assert_user_ids "${USER_NAME}" "${USER_UID}" "${USER_GID}"
    log "INFO" "User '${USER_NAME}' (UID ${USER_UID}, GID ${USER_GID}) already exists — skipping"
else
    useradd --uid "${USER_UID}" \
            --gid "${USER_GID}" \
            --no-create-home \
            --shell /bin/bash \
            --comment "SLURM job execution user" \
            "${USER_NAME}"
    log "INFO" "Created user '${USER_NAME}' with UID ${USER_UID} (home on NFS)"
    log "WARN" "Set a password for '${USER_NAME}': sudo passwd ${USER_NAME}"
fi

# =============================================================================
# Admin user (verify UID/GID and sudo access)
# =============================================================================
ensure_group "${ADMIN_NAME}" "${ADMIN_GID}"
if id "${ADMIN_NAME}" &>/dev/null; then
    assert_user_ids "${ADMIN_NAME}" "${ADMIN_UID}" "${ADMIN_GID}"
    log "INFO" "Admin user '${ADMIN_NAME}' (UID ${ADMIN_UID}, GID ${ADMIN_GID}) exists"
    if groups "${ADMIN_NAME}" | grep -q "sudo"; then
        log "INFO" "User '${ADMIN_NAME}' already has sudo privileges"
    else
        usermod -aG sudo "${ADMIN_NAME}"
        log "INFO" "Added '${ADMIN_NAME}' to sudo group"
    fi
else
    log "WARN" "Admin user '${ADMIN_NAME}' not found — creating without password"
    useradd --uid "${ADMIN_UID}" \
            --gid "${ADMIN_GID}" \
            --create-home \
            --shell /bin/bash \
            --groups sudo \
            "${ADMIN_NAME}"
    log "WARN" "Run: sudo passwd ${ADMIN_NAME}"
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

log "INFO" "=== User creation complete on $(hostname) ==="
log "INFO" "Next step: sudo bash 04-chrony.sh"
