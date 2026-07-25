# Task: Design and Document a Raspberry Pi 5 SLURM Cluster

You are a Linux systems engineer and HPC cluster administrator.

Your task is to design, document, and automate the deployment of a small SLURM cluster built from Raspberry Pi 5 boards.

**Important:** This cluster has a **proven working configuration**. Treat the section *Proven working configuration (do not invent)* as the source of truth. Prefer that design over generic enterprise HPC defaults when they conflict (especially cgroup v2 job isolation, alternate auth plugin field names, multi-partition layouts, or placeholder `192.168.1.x` addresses).

## Hardware Inventory

### Raspberry Pi Cluster Nodes

* 4 × Raspberry Pi 5 (16 GB RAM)
* 4 × Raspberry Pi 5 M.2 NVMe M-Key 2242 + PoE HAT (third-party combined M.2 + PoE boards)
* 4 × Transcend 256 GB NVMe PCIe Gen3 x4 M.2 2242 SSD
* 1 × NETGEAR GS305EPP 5-port Gigabit PoE+ switch (802.3at; 120 W budget)
* 1 × External USB SSD (1 TB) for shared storage (attached to pi-node0)

## Cluster Architecture

### Network

* Subnet: `192.168.129.0/24`
* Gateway / DNS: `192.168.128.1`
* Name resolution: `/etc/hosts` on every node (no cluster DNS required)
* Network manager: NetworkManager (`nmcli`) on Raspberry Pi OS Trixie
* Cluster name: `picluster`

### Node Roles

| Hostname | IP Address      | Role                                              |
| -------- | --------------- | ------------------------------------------------- |
| pi-node0 | 192.168.129.36  | Head node, SLURM controller, NFS server, compute  |
| pi-node1 | 192.168.129.37  | Compute node                                      |
| pi-node2 | 192.168.129.38  | Compute node                                      |
| pi-node3 | 192.168.129.39  | Compute node                                      |

### Requirements

All four Raspberry Pi systems must be available for computation, including `pi-node0` (head node doubles as compute). Do not reserve pi-node0 as controller-only unless documenting that as an explicit alternative with trade-offs.

## Operating System

Use:

* Raspberry Pi OS Lite (64-bit)
* Debian Trixie
* Release date: 21 April 2026 or newer

Prefer packages available directly from Debian/Raspberry Pi APT repositories whenever possible.

Avoid compiling software from source unless absolutely necessary.

SLURM version target: **24.11.x** from Debian Trixie APT (`slurm-wlm`, `slurmctld`, `slurmd`, `slurm-client`).

## Proven Working Configuration (Do Not Invent)

The following settings match a live, validated cluster. **Do not substitute** textbook/default alternatives unless explicitly placed under Future Improvements.

### SLURM (`/etc/slurm/slurm.conf`)

```text
ClusterName=picluster
SlurmctldHost=pi-node0
AuthType=auth/munge
CryptoType=crypto/munge
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory
ProctrackType=proctrack/linuxproc
TaskPlugin=task/affinity
MpiDefault=pmix
MailProg=/usr/local/bin/slurm-no-mail
StateSaveLocation=/var/spool/slurm/ctld
SlurmdSpoolDir=/var/spool/slurm/d
SlurmctldPort=6817
SlurmdPort=6818
ReturnToService=2
RealMemory=15000   # verify with: free -m ; adjust if needed
PartitionName=compute Nodes=pi-node[0-3] Default=YES MaxTime=INFINITE State=UP
```

NodeAddr values must match the IP table above.

**Do not use by default:**

* `CredType=cred/munge` (use `CryptoType=crypto/munge`)
* `ProctrackType=proctrack/cgroup` or `TaskPlugin=task/cgroup`
* Multiple partitions (`all` / `debug`) unless documented as optional alternatives
* `cgroup_enable=memory` in `/boot/firmware/cmdline.txt` for the default path

### SLURM cgroups (`/etc/slurm/cgroup.conf`)

```text
CgroupPlugin=disabled
CgroupAutomount=yes
ConstrainCores=no
ConstrainRAMSpace=no
ConstrainDevices=no
```

Cgroup v2 job isolation (`CgroupPlugin=autodetect`, `proctrack/cgroup`, `cgroup_enable=memory`) belongs only under **Future Improvements**.

### Required Side Effects (Must Automate and Document)

1. **Mail stub:** Create `/usr/local/bin/slurm-no-mail` (`#!/bin/sh` / `exit 0`). Raspberry Pi OS Lite has no MTA; without this, `slurmctld` fatals with `Configured MailProg is invalid`.
2. **`slurmctld` as root:** Install systemd drop-in `/etc/systemd/system/slurmctld.service.d/override.conf` with `User=root` and `Group=root`, then `daemon-reload`. Package `slurm` user can hit privilege errors on start.
3. **PMIx:** `apt install libpmix-dev` on all nodes (`MpiDefault=pmix`).
4. **Do not** append `cgroup_enable=memory` by default.

## User Accounts

Create users with **identical UIDs/GIDs on every node before** installing `munge` / SLURM packages:

| Account | UID/GID | Notes |
| ------- | ------- | ----- |
| munge   | 64003   | System user; `/usr/sbin/nologin` |
| slurm   | 64002   | System user |
| user    | 2000    | SLURM job execution; no sudo |
| admin   | (Imager / existing) | sudo privileges; SSH enabled |

### SSH

* Passwordless SSH for `admin` between all nodes (required for ops and config distribution).
* Passwordless SSH for `user` between all nodes (required for MPI / job workflows).
* Head-node scripts that run remote `sudo` over SSH need either:
  * `admin ALL=(ALL) NOPASSWD: ALL` in `/etc/sudoers.d/cluster-admin` on workers, or
  * interactive `ssh -t` so sudo can prompt, or
  * prefer **scp to `/tmp` + local sudo on compute scripts** for sensitive installs (`munge.key`, `slurm.conf`).

Document the chosen privilege model and its trade-offs.

## Software Stack (APT)

Install via APT on the appropriate nodes:

* SLURM packages from Trixie (`slurm-wlm` / `slurmctld` on head; `slurmd` + `slurm-client` on all compute-capable nodes)
* `libpmix-dev` on all nodes
* `chrony` — pi-node0 is NTP server for `192.168.129.0/24`; compute nodes prefer `server pi-node0 iburst prefer`
* NFS: `nfs-kernel-server` on pi-node0; `nfs-common` on computes
* OpenMPI: `openmpi-bin`, `openmpi-common`, `libopenmpi-dev`
* `stress-ng` for CPU stress tests

## Research Requirements

Before producing the solution:

1. Verify package names and versions on Debian Trixie **arm64** (`slurm-wlm`, `libpmix-dev`, OpenMPI).
2. Confirm Raspberry Pi 5 NVMe boot requirements (EEPROM `BOOT_ORDER`, `PCIE_PROBE=1`, `dtparam=pciex1`).
3. Confirm MUNGE and NFS practices for a small Ethernet cluster.
4. Identify RPi5-specific caveats (PoE, third-party HATs, cloud-init, thermal).

**Constraint:** Research may verify and explain the Proven configuration. It **must not override** Proven settings when generic enterprise HPC guidance conflicts (especially enabling cgroup job isolation by default). If research prefers cgroup v2 enforcement, document it only under Future Improvements.

For every significant recommendation:

* explain why it was chosen,
* explain alternatives,
* document any trade-offs.

## Must-Include Caveats (Document and Automate)

These are requirements, not optional research notes:

| Topic | Requirement |
| ----- | ----------- |
| PoE power | PoE is the **sole** power source. **Never** connect USB-C power while PoE is active (hardware damage risk). |
| GS305EPP | Use 802.3at (PoE+). Lower-numbered ports have PoE priority if budget is contested. |
| Third-party M.2 + PoE HAT | Enable `dtparam=pciex1`; Gen3 (`dtparam=pciex1_gen=3`) optional/benchmark; EEPROM `PCIE_PROBE=1` as needed. |
| cloud-init | After writing `/etc/hosts`, run `touch /etc/cloud/cloud-init.disabled` on all nodes so hosts are not rewritten on reboot. |
| USB shared disk | Mount by UUID; fstab options include `nofail` (and typically `noatime`). |
| NFS client mounts | Use `_netdev` (and soft mounts with timeouts as appropriate). |
| NFS shutdown order | Unmount NFS on compute nodes **before** stopping NFS / powering off pi-node0. Document `umount -l` for stale mounts. |
| OpenMPI / IPv6 | Dual-stack TCP can hang; require `OMPI_MCA_btl_tcp_disable_family=6` for `srun`/batch and `-mca btl_tcp_disable_family 6` for bare `mpirun`. Prefer `srun` under SLURM. |

Troubleshooting must include an **Operational caveats table** covering at least: cloud-init hosts rewrite, MailProg invalid, slurmctld root override, OpenMPI IPv6, PMIx/`libpmix-dev`, cgroups-disabled expectation, USB-C+PoE, NFS stale/shutdown order.

## Deliverables

Produce a complete deployment guide in Markdown.

The guide must be written as if it will be followed from a clean installation.

### Deliverable 1: Architecture Overview

Provide:

* cluster topology
* network design (live IPs, subnet, gateway, `/etc/hosts`, cloud-init disable)
* storage design (USB on pi-node0, NFS exports/mounts)
* authentication design (MUNGE, fixed UIDs)
* SLURM architecture (Proven settings; head also runs `slurmd`)

### Deliverable 2: Installation Guide

Document:

1. NVMe boot configuration (EEPROM, PCIe; **no** default `cgroup_enable=memory`)
2. Raspberry Pi OS installation
3. Static network configuration (`nmcli`)
4. Hostname configuration
5. `/etc/hosts` + **disable cloud-init**
6. User creation (fixed UIDs)
7. SSH configuration (passwordless `admin` and `user`)
8. Chrony configuration (head as cluster NTP)
9. NFS shared storage configuration (UUID, `nofail`, `_netdev`)
10. MUNGE configuration
11. SLURM installation (including mail stub, `slurmctld` root override, `libpmix-dev`)
12. SLURM configuration (Proven `slurm.conf` / `cgroup.conf`)
13. Cluster validation

Include verification commands after every major step.

### Deliverable 3: Caveats and Troubleshooting

Document:

* Raspberry Pi 5 hardware caveats (including PoE / USB-C dual-power)
* NVMe boot caveats
* PoE / GS305EPP considerations
* cloud-init / `/etc/hosts` issues
* Time synchronization issues
* MUNGE issues
* NFS issues (boot hangs, shutdown order, stale handles)
* SLURM issues (MailProg, root override, cgroups-disabled path)
* OpenMPI / PMIx / IPv6 issues

Provide:

* An **Operational caveats table** (required)
* Troubleshooting procedures and diagnostic commands

### Deliverable 4: Automation Scripts

Generate production-ready Bash scripts.

#### SCRIPT RULES

* Scripts must be idempotent.
* Scripts must use `set -euo pipefail`.
* Scripts must include comments.
* Scripts must validate prerequisites.
* Scripts must log actions (e.g. `/var/log/pi-cluster-setup.log`).
* Scripts must be safe to rerun.
* Config values in scripts **must match** the Proven working configuration (IPs, `picluster`, SLURM settings).
* `01-base-system.sh`: install packages including `libpmix-dev`; do **not** force `cgroup_enable=memory`.
* `02-network.sh`: static IP + hostname + `/etc/hosts` + `cloud-init.disabled`.
* `05-nfs-server.sh`: USB by UUID; fstab includes `nofail`.
* `06-munge.sh`: do **not** regenerate `/etc/munge/munge.key` if it already exists; distribute only when newly generated or explicitly rotated.
* `07-slurm-controller.sh`: create mail stub and `slurmctld` root override **before** starting daemons; write Proven `slurm.conf` / `cgroup.conf`.
* Ops scripts: unmount NFS on compute nodes before stopping NFS on the head node.
* Document privilege model for remote sudo (NOPASSWD vs `ssh -t` vs scp + local sudo). Prefer scp-to-`/tmp` + local sudo on compute for sensitive installs where practical.
* Provide `scripts/scripts.md` indexing each script and its side effects.

Organize scripts into:

#### Head Node Scripts

```text
01-base-system.sh
02-network.sh
03-users.sh
04-chrony.sh
05-nfs-server.sh
06-munge.sh
07-slurm-controller.sh
```

#### Compute Node Scripts

```text
01-base-system.sh
02-network.sh
03-users.sh
04-chrony.sh
05-nfs-client.sh
06-munge.sh
07-slurm-node.sh
```

### Deliverable 5: Cluster Operations

Provide scripts and procedures under `scripts/ops/`:

#### Startup

* start all services in dependency order (munge → storage/NFS → slurmctld → slurmd)
* validate cluster health (`sinfo`, service status)

#### Shutdown

* drain SLURM jobs
* stop slurmd on computes
* stop slurmctld
* **unmount NFS on compute nodes**
* stop NFS on head
* shutdown compute nodes, then controller

#### Reboot

* rolling reboot
* full cluster reboot

Example ops scripts:

```text
cluster-startup.sh
cluster-shutdown.sh
cluster-reboot.sh
```

### Deliverable 6: Validation and Testing

Provide:

* commands to verify MUNGE
* commands to verify NFS
* commands to verify SLURM
* sample SLURM batch jobs (`--partition=compute`)
* CPU stress test example (`stress-ng`)
* distributed MPI test example:
  * install OpenMPI + `libpmix-dev`
  * prefer `srun` over bare `mpirun`
  * require `OMPI_MCA_btl_tcp_disable_family=6` (or `-mca btl_tcp_disable_family 6`)

### Deliverable 7: Final Configuration Files

Provide complete contents of:

```text
/etc/hosts
/etc/exports
/etc/chrony/chrony.conf   (head and compute variants)
/etc/munge/munge.key deployment process
/etc/slurm/slurm.conf     (Proven settings)
/etc/slurm/cgroup.conf    (CgroupPlugin=disabled)
/usr/local/bin/slurm-no-mail
/etc/systemd/system/slurmctld.service.d/override.conf
```

Do not omit sections with placeholders.

Generate complete working examples matching the live IPs and Proven configuration.

## Output Format

Structure the final response / guide as:

1. Research Findings
2. Architecture Decisions
3. Deployment Guide
4. Configuration Files
5. Automation Scripts
6. Operations Guide
7. Validation Procedures
8. Troubleshooting Guide (including Operational caveats table)
9. Future Improvements (cgroup v2 enforcement may appear here only)

### Output files (repository layout)

Write artifacts to:

```text
documents/guide.md
scripts/head-node/*.sh
scripts/compute-node/*.sh
scripts/ops/cluster-startup.sh
scripts/ops/cluster-shutdown.sh
scripts/ops/cluster-reboot.sh
scripts/scripts.md
```

Do not invent alternate directory layouts.

Assume the reader has basic Linux knowledge but no prior SLURM administration experience.

Where information is uncertain or version-dependent, explicitly state assumptions and provide verification steps.
