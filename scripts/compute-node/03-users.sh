#!/usr/bin/env bash
# =============================================================================
# 03-users.sh — Compute Node: User Account Creation
# Raspberry Pi 5 SLURM Cluster (pi-node1 / pi-node2 / pi-node3)
#
# Creates the same users with identical UIDs as the head node.
# This script is functionally identical to head-node/03-users.sh.
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

MUNGE_UID=64003
MUNGE_GID=64003
SLURM_UID=64002
SLURM_GID=64002
USER_UID=2000
USER_GID=2000
USER_NAME="user"
ADMIN_NAME="admin"

log "INFO" "=== Creating cluster user accounts on $(hostname) ==="

ensure_group() {
    local gname="$1" gid="$2"
    if getent group "${gname}" &>/dev/null; then
        local existing_gid
        existing_gid=$(getent group "${gname}" | cut -d: -f3)
        [[ "${existing_gid}" == "${gid}" ]] || die "Group '${gname}' has GID ${existing_gid}, expected ${gid}"
        log "INFO" "Group '${gname}' (GID ${gid}) exists — ok"
    else
        groupadd --gid "${gid}" "${gname}"
        log "INFO" "Created group '${gname}' GID ${gid}"
    fi
}

ensure_system_user() {
    local uname="$1" uid="$2" gid="$3"
    if id "${uname}" &>/dev/null; then
        local existing_uid
        existing_uid=$(id -u "${uname}")
        [[ "${existing_uid}" == "${uid}" ]] || die "User '${uname}' has UID ${existing_uid}, expected ${uid}"
        log "INFO" "User '${uname}' (UID ${uid}) exists — ok"
    else
        useradd --uid "${uid}" --gid "${gid}" --no-create-home --shell /usr/sbin/nologin --system "${uname}"
        log "INFO" "Created system user '${uname}' UID ${uid}"
    fi
}

ensure_group "munge" "${MUNGE_GID}"
ensure_system_user "munge" "${MUNGE_UID}" "${MUNGE_GID}"

ensure_group "slurm" "${SLURM_GID}"
ensure_system_user "slurm" "${SLURM_UID}" "${SLURM_GID}"

if id "${USER_NAME}" &>/dev/null; then
    log "INFO" "User '${USER_NAME}' already exists"
else
    getent group "${USER_NAME}" &>/dev/null || groupadd --gid "${USER_GID}" "${USER_NAME}"
    useradd --uid "${USER_UID}" --gid "${USER_GID}" --no-create-home \
        --shell /bin/bash --comment "SLURM job execution user" "${USER_NAME}"
    log "INFO" "Created user '${USER_NAME}' UID ${USER_UID} (home on NFS)"
fi

if id "${ADMIN_NAME}" &>/dev/null; then
    log "INFO" "Admin user '${ADMIN_NAME}' exists"
else
    log "WARN" "Admin user '${ADMIN_NAME}' not found — creating without password"
    useradd --create-home --shell /bin/bash --groups sudo "${ADMIN_NAME}"
    log "WARN" "Run: sudo passwd admin"
fi

log "INFO" "User verification:"
for u in munge slurm "${USER_NAME}" "${ADMIN_NAME}"; do
    id "${u}" 2>/dev/null | tee -a "${LOG_FILE}" || log "WARN" "User ${u} not found"
done

log "INFO" "=== User creation complete on $(hostname) ==="
log "INFO" "Next step: sudo bash 04-chrony.sh"
