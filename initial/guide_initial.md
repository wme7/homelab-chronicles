# Raspberry Pi 5 SLURM Cluster — Setup Guide

**Hardware:** 4× Raspberry Pi 5 (16 GB) · M.2 NVMe 2242 + PoE HAT · Transcend 256 GB NVMe · NETGEAR GS305EPP · 1 TB USB storage  
**OS:** Raspberry Pi OS Lite 64-bit — Debian 13 Trixie (21 Apr 2026)  
**Users:** `admin` (root-capable) · `user` (non-root compute user)

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Hardware Assembly & Caveats](#2-hardware-assembly--caveats)
3. [OS Installation on NVMe (Headless)](#3-os-installation-on-nvme-headless)
4. [Network & Hostname Configuration](#4-network--hostname-configuration)
5. [User Setup (admin & user)](#5-user-setup-admin--user)
6. [Time Synchronisation (chrony)](#6-time-synchronisation-chrony)
7. [Passwordless SSH Between Nodes](#7-passwordless-ssh-between-nodes)
8. [Shared Storage — NFS + USB Drive](#8-shared-storage--nfs--usb-drive)
9. [MUNGE Authentication](#9-munge-authentication)
10. [SLURM Installation & Configuration](#10-slurm-installation--configuration)
11. [Verifying the Cluster](#11-verifying-the-cluster)
12. [OpenMPI Installation](#12-openmpi-installation)
13. [Running MPI Jobs with C/C++](#13-running-mpi-jobs-with-cc)
14. [Running MPI Jobs with Python (mpi4py)](#14-running-mpi-jobs-with-python-mpi4py)
15. [SLURM Job Management Cheatsheet](#15-slurm-job-management-cheatsheet)
16. [Known Caveats & Troubleshooting](#16-known-caveats--troubleshooting)

---

## Script index (`initial/`)

These are the manual, step-by-step scripts that accompany this guide. Run them in ascending order after completing the matching guide section. For the later automated equivalents, see [`scripts/`](../scripts/).

### Head node (`initial/head-node/`) — run on **pi-node0**

| Script | Guide section |
|--------|---------------|
| `01-users.sh` | §5 |
| `02-ssh-users.sh` | §7 |
| `03-usb-drive.sh` | §8.1 |
| `04-shared-dirs.sh` | §8.2 |
| `05-nfs-server.sh` | §8.3 |
| `06-munge-key.sh` | §9.2–9.3 |
| `07-slurm-dirs.sh` | §10.2 |
| `08-slurm-no-mail.sh` | §10.4 |
| `09-slurm-conf.sh` | §10.5 |
| `10-slurm-cgroup-conf.sh` | §10.6 |
| `11-distribute-slurm-conf.sh` | §10.7 |

### Compute node (`initial/compute-node/`) — run on **pi-node1–3**

| Script | Guide section |
|--------|---------------|
| `01-users.sh` | §5 |
| `02-admin-sudoers.sh` | §5.1 / §16 |
| `03-nfs-client.sh` | §8.4–8.5 |
| `04-munge-key.sh` | §9.3 |
| `05-slurm-dirs.sh` | §10.2 |
| `06-slurm-cgroup-conf.sh` | §10.6 |

**No script (manual only):** §3 OS/NVMe, §4 network/hosts (+ cloud-init disable), §6 chrony, §9.1/9.4–9.5 munge install/start/test, §10.1 package install, §10.8 start daemons, §8.6 shutdown order, §11–15 verify/OpenMPI/jobs. Automated startup/shutdown lives under [`scripts/ops/`](../scripts/ops/).

---

## 1. Architecture Overview

```
            [Your laptop / desktop]
                      |
                  (SSH / web)
                      |
        ┌─────────────────────────────┐
        │   NETGEAR GS305EPP          │  120 W PoE+ budget
        │   (4× PoE+ ports active)    │  30 W per port max
        └──┬───────┬───────┬──────┬──┘
           │       │       │      │
        pi-node0  pi-node1  pi-node2  pi-node3
        .129.36   .129.37   .129.38   .129.39
        (SLURM    (compute) (compute) (compute)
        controller
        + NFS server)
```

**All four nodes are compute nodes.** `pi-node0` additionally runs `slurmctld` (scheduler controller) and the NFS server. This is the typical "head node doubles as a compute node" pattern for small learning clusters.

| Component | Role |
|-----------|------|
| `pi-node0` | SLURM controller (`slurmctld`), NFS server, compute node (`slurmd`) |
| `pi-node1–3` | Compute nodes (`slurmd`) only |
| USB 1 TB disk | Attached to `pi-node0`, exported via NFS as `/shared` |

---

## 2. Hardware Assembly & Caveats

### 2.1 PoE HAT + NVMe HAT Combination

Your HATs are the combined **M.2 NVMe M-Key + PoE+** boards (e.g., 52Pi, GeeekPi P33, or Waveshare POE M.2 HAT+). These route both PCIe (for NVMe) and PoE power through a single board stacked on the Pi 5.

> ⚠️ **Critical caveat:** When the PoE HAT is supplying power, **never connect the USB-C port** on the Pi 5 to another power supply simultaneously. Doing so can damage the board or the HAT. The PoE connection is the sole power source.

### 2.2 PoE Power Budget

The **GS305EPP** provides a **120 W total PoE+ budget**, with up to **30 W per port** (802.3at). Each Pi 5 with NVMe under typical load draws roughly 10–15 W, so four nodes comfortably sit within budget (~60 W combined). Under heavy sustained compute load, budget ~20 W per node to be safe.

### 2.3 PCIe Gen 3 vs Gen 2

The Raspberry Pi 5 PCIe interface defaults to **Gen 2** for stability. The Transcend NVMe is Gen 3 capable. To unlock Gen 3 speeds, add the following to `/boot/firmware/config.txt` **after** initial setup:

```ini
dtparam=pciex1_gen=3
```

Benchmark after enabling to verify stability. Some SSDs behave erratically at Gen 3 on Pi 5; if you see I/O errors in `dmesg`, revert to Gen 2 (remove the line).

### 2.4 Active Cooling

The combined PoE + NVMe HATs usually include or recommend an active cooler. Ensure it is installed on each Pi — under sustained MPI workloads, the Pi 5 will throttle without cooling.

---

## 3. OS Installation on NVMe (Headless)

> **Script coverage:** none — follow this section manually on each node.

Do this process **once per node**. The fastest approach uses a microSD card as a bootstrap medium.

### Step 1 — Flash microSD with Raspberry Pi OS Full (Desktop)

On your laptop:

1. Download **Raspberry Pi Imager** from `https://www.raspberrypi.com/software/`
2. Select **Raspberry Pi OS (64-bit) — Full** (desktop version — needed to install `rpi-imager` on the Pi itself).
3. Before writing, click the ⚙️ gear icon and configure:
   - Hostname: `pi-node0` (adjust per node)
   - Enable SSH → Use password authentication
   - Username: `admin` / Password: (choose a strong password)
   - Locale / timezone as appropriate

4. Write to the microSD card.

### Step 2 — Boot from microSD, then flash NVMe

Insert the microSD, power on via PoE, wait ~60 s, then SSH in:

```bash
ssh admin@192.168.129.36   # adjust IP for each node
```

Once logged in, update the system and install the Trixie image onto the NVMe:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install rpi-imager -y

# Download the Trixie Lite image
wget https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-04-22/2026-04-22-raspios-trixie-arm64-lite.img.xz

# Flash to NVMe (confirm device with: lsblk)
sudo rpi-imager --cli 2026-04-22-raspios-trixie-arm64-lite.img.xz /dev/nvme0n1
```

> **Note:** Update the filename above to the actual Trixie release from 21 Apr 2026. Check `https://downloads.raspberrypi.com/raspios_lite_arm64/images/` for the exact URL.

### Step 3 — Copy boot configuration to NVMe

Copy your SSH / user / config files so the NVMe image boots headlessly:

```bash
sudo mkdir -p /mnt/nvfat
sudo mount /dev/nvme0n1p1 /mnt/nvfat

# Copy headless config from the microSD boot partition
sudo cp /boot/firmware/user-data   /mnt/nvfat/
sudo cp /boot/firmware/network-config /mnt/nvfat/
sudo cp /boot/firmware/config.txt  /mnt/nvfat/

sudo umount /mnt/nvfat
```

### Step 4 — Configure EEPROM for NVMe boot

```bash
sudo raspi-config
# → Advanced Options → Boot Order → NVMe/USB boot
# OR manually:
sudo -E rpi-eeprom-config --edit
# Set: BOOT_ORDER=0xf416  (SD first, then NVMe)
# For NVMe-first: BOOT_ORDER=0xf614
sudo reboot
```

After reboot: remove the microSD card. The Pi should now boot from NVMe.

### Step 5 — Verify NVMe boot

```bash
lsblk
# Should show nvme0n1 as root (/) device

# Optional: enable PCIe Gen3
echo "dtparam=pciex1_gen=3" | sudo tee -a /boot/firmware/config.txt
sudo reboot
```

**Repeat Steps 1–5 for each node** (`pi-node1` through `pi-node3`), using the appropriate hostname and IP.

---

## 4. Network & Hostname Configuration

> **Script coverage:** none — follow this section manually on each node.

Do the following **on every node**.

### 4.1 Set hostname

```bash
# On pi-node0:
sudo hostnamectl set-hostname pi-node0

# On pi-node1:
sudo hostnamectl set-hostname pi-node1
# ... etc.
```

### 4.2 Edit /etc/hosts (all nodes)

Add the cluster nodes to `/etc/hosts` on **every node** so names resolve without DNS:

```bash
sudo tee -a /etc/hosts << 'EOF'

# Pi Cluster
192.168.129.36  pi-node0
192.168.129.37  pi-node1
192.168.129.38  pi-node2
192.168.129.39  pi-node3
EOF
```

### 4.3 Verify connectivity

```bash
ping -c 3 pi-node1
ping -c 3 pi-node2
ping -c 3 pi-node3
```

### 4.4 Disable cloud-init (all nodes)

Raspberry Pi OS may re-write `/etc/hosts` on reboot via cloud-init. Disable it **after** hosts are correct:

```bash
sudo touch /etc/cloud/cloud-init.disabled
```

See [§16](#16-known-caveats--troubleshooting) and [Raspberry Pi forum discussion](https://forums.raspberrypi.com/viewtopic.php?t=396567).

---

## 5. User Setup (admin & user)

> **Scripts:** `initial/head-node/01-users.sh` · `initial/compute-node/01-users.sh`

**Critical:** `slurm` and `munge` system users must have **identical UIDs and GIDs on all nodes**. The `user` user must also match across all nodes.

Run the following block **on every node** in the same order:

```bash
# Create munge system user (UID/GID 900)
sudo groupadd -g 900 munge 2>/dev/null || true
sudo useradd -m -c "MUNGE authentication" -d /var/lib/munge \
    -u 900 -g munge -s /usr/sbin/nologin munge 2>/dev/null || true

# Create slurm system user (UID/GID 901)
sudo groupadd -g 901 slurm 2>/dev/null || true
sudo useradd -m -c "Slurm workload manager" -d /var/lib/slurm \
    -u 901 -g slurm -s /bin/bash slurm 2>/dev/null || true

# Create the non-root compute user 'user' (UID/GID 1002)
sudo groupadd -g 1002 user 2>/dev/null || true
sudo useradd -m -u 1002 -g user -s /bin/bash user 2>/dev/null || true
sudo passwd user   # set a password
```

> If `admin` was created by Raspberry Pi Imager at UID 1000, that is fine — leave it. The important constraint is that `munge`, `slurm`, and `user` share the same UID/GID across every node.

### 5.1 Admin passwordless sudo on compute nodes

> **Script:** `initial/compute-node/02-admin-sudoers.sh`

Head-node scripts that `scp`/`ssh` and run remote `sudo` (MUNGE key, SLURM conf distribute) need passwordless sudo for `admin` on workers. Privilege mixing between package users and SSH remote installs makes a limited sudoers list unreliable — use:

```bash
echo 'admin ALL=(ALL) NOPASSWD: ALL' \
  | sudo tee /etc/sudoers.d/cluster-admin
sudo chmod 0440 /etc/sudoers.d/cluster-admin
```

Run this on **pi-node1, pi-node2, pi-node3** (and optionally on pi-node0) before §7–§11 remote operations.

---

## 6. Time Synchronisation (chrony)

> **Script coverage:** none — install and enable chrony manually on every node.

MUNGE credentials expire after 300 seconds and require clocks to be in sync (within ~1 minute by default). Install chrony on all nodes:

```bash
sudo apt install chrony -y
sudo systemctl enable --now chrony
```

Verify sync:

```bash
chronyc tracking
```

---

## 7. Passwordless SSH Between Nodes

> **Script:** `initial/head-node/02-ssh-users.sh`

The SLURM controller and compute jobs need passwordless SSH between nodes, especially for the `admin` and `user` users. Complete §5.1 (admin NOPASSWD sudo) on workers before relying on remote `sudo` over SSH.

Run **on pi-node0** for each user who will submit jobs:

```bash
# For admin user
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
for node in pi-node1 pi-node2 pi-node3; do
    ssh-copy-id admin@$node
done

# For user user
sudo -u user bash -c '
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
'
for node in pi-node1 pi-node2 pi-node3; do
    sudo -u user ssh-copy-id user@$node
done
```

Also copy `pi-node0`'s own public key to itself (loopback):

```bash
ssh-copy-id admin@pi-node0
sudo -u user ssh-copy-id user@pi-node0
```

---

## 8. Shared Storage — NFS + USB Drive

SLURM assumes a **shared filesystem** — job scripts and output files must be accessible on all nodes at the same path.

### 8.1 Mount the USB drive on pi-node0

> **Script:** `initial/head-node/03-usb-drive.sh`

```bash
# Find the USB device — confirm with lsblk before formatting
lsblk

# Create a filesystem (if not already formatted)
# Script uses /dev/sda (whole disk). Prefer /dev/sda1 if a partition table exists.
# WARNING: wrong device destroys data — always verify with lsblk first.
sudo mkfs.ext4 /dev/sda   # adjust device as needed

# Create mount point and mount
sudo mkdir -p /shared
sudo mount /dev/sda /shared

# Make it persistent
echo "UUID=$(blkid -s UUID -o value /dev/sda) /shared ext4 defaults,nofail 0 2" \
    | sudo tee -a /etc/fstab
```

### 8.2 Create shared directories

> **Script:** `initial/head-node/04-shared-dirs.sh`

```bash
sudo mkdir -p /shared/home/user /shared/scratch /shared/software
sudo chown -R user:user /shared/home/user
sudo chown -R root:root /shared/scratch
sudo chmod 1777 /shared/scratch
```

### 8.3 Configure NFS server on pi-node0

> **Script:** `initial/head-node/05-nfs-server.sh`

```bash
sudo apt install nfs-kernel-server -y

sudo tee /etc/exports << 'EOF'
/shared  192.168.129.0/24(rw,sync,no_root_squash,no_subtree_check)
EOF

sudo exportfs -rav
sudo systemctl enable --now nfs-server
```

### 8.4 Mount NFS on compute nodes (pi-node1, pi-node2, pi-node3)

> **Script:** `initial/compute-node/03-nfs-client.sh` (includes §8.5 home remap)

Run **on each worker node**:

```bash
sudo apt install nfs-common -y
sudo mkdir -p /shared

echo "pi-node0:/shared  /shared  nfs  defaults,_netdev  0  0" \
    | sudo tee -a /etc/fstab

sudo mount -a
ls /shared   # should show home, scratch, software
```

### 8.5 Point user's home to the shared directory

On **all nodes**:

```bash
sudo usermod -d /shared/home/user user
```

### 8.6 Shutting down the cluster safely

> **Script coverage:** none under `initial/` — see also [`scripts/ops/cluster-shutdown.sh`](../scripts/ops/cluster-shutdown.sh) for the automated version.

Because the worker nodes have `/shared` mounted over NFS from `pi-node0`, order matters when powering off — unmounting before stopping the NFS server prevents stale file handles and filesystem corruption.

**On pi-node1, pi-node2, pi-node3 first:**

```bash
# Drain the node so SLURM stops dispatching jobs, then stop slurmd
sudo scontrol update NodeName=$(hostname) State=DRAIN Reason="shutdown"
sudo systemctl stop slurmd

# Unmount the shared NFS volume
sudo umount /shared
sudo poweroff
```

**Then on pi-node0 last:**

```bash
# Stop the SLURM controller
sudo systemctl stop slurmctld
sudo systemctl stop slurmd

# Stop the NFS server (all clients must be unmounted first)
sudo systemctl stop nfs-server

# Unmount and sync the USB drive
sudo umount /shared
sudo poweroff
```

> ⚠️ **Never power off pi-node0 while worker nodes still have `/shared` mounted.** NFS clients will hang on any file I/O and may require a hard reboot to recover. If a worker node becomes unresponsive with a stale NFS mount, run `sudo umount -l /shared` (lazy unmount) to detach it without waiting for the server.

---

## 9. MUNGE Authentication

MUNGE authenticates messages between SLURM daemons. The **same `munge.key` must be on every node**.

### 9.1 Install MUNGE on all nodes

> **Script coverage:** none — install packages manually.

```bash
sudo apt install munge libmunge-dev -y
```

### 9.2 Generate key on pi-node0 only

> **Script:** `initial/head-node/06-munge-key.sh` — fixes ownership/mode and distributes; key generation via `dd` is commented out because the package often already creates a key. Uncomment `dd` only if you need to regenerate.

```bash
# On pi-node0 (only if regenerating — otherwise keep the package key):
# sudo dd if=/dev/urandom bs=1 count=1024 of=/etc/munge/munge.key
sudo chown munge:munge /etc/munge/munge.key
sudo chmod 400 /etc/munge/munge.key
```

### 9.3 Copy key to all other nodes

> **Scripts:** head `06-munge-key.sh` (scp to `/tmp`) · compute `04-munge-key.sh` (install into `/etc/munge/`)

```bash
# On pi-node0:
for node in pi-node1 pi-node2 pi-node3; do
    sudo scp /etc/munge/munge.key admin@$node:/tmp/munge.key
    ssh admin@$node "
        sudo mv /tmp/munge.key /etc/munge/munge.key
        sudo chown munge:munge /etc/munge/munge.key
        sudo chmod 400 /etc/munge/munge.key
    "
done
```

### 9.4 Start MUNGE on all nodes

> **Script coverage:** none — enable the service manually.

```bash
# Run on every node:
sudo systemctl enable --now munge
```

### 9.5 Test MUNGE

> **Script coverage:** none — verify manually.

```bash
# From pi-node0 — should return STATUS: Success
munge -n | ssh admin@pi-node1 unmunge
```

---

## 10. SLURM Installation & Configuration

### 10.1 Install SLURM packages on all nodes

> **Script coverage:** none — install packages manually.

```bash
# On ALL nodes:
sudo apt install slurm-wlm slurmd -y

# On pi-node0 only (controller):
sudo apt install slurmctld -y
```

### 10.2 Create required directories on all nodes

> **Scripts:** `initial/head-node/07-slurm-dirs.sh` · `initial/compute-node/05-slurm-dirs.sh`

```bash
sudo mkdir -p /var/spool/slurm/d /var/log/slurm
sudo chown slurm:slurm /var/spool/slurm/d /var/log/slurm

# On pi-node0 only:
sudo mkdir -p /var/spool/slurm/ctld
sudo chown slurm:slurm /var/spool/slurm/ctld
```

### 10.3 Determine node hardware specs

Run on **each node** and note the output:

```bash
nproc               # CPU count
free -m | awk '/Mem:/{print $2}'   # RAM in MB
```

Expected for Pi 5 16 GB: `nproc = 4`, RAM ≈ `15000` MB (some reserved by GPU/OS).

### 10.4 Create the no-op mail stub (pi-node0 only)

> **Script:** `initial/head-node/08-slurm-no-mail.sh`

Raspberry Pi OS Lite does not include a mail agent. Without this step, `slurmctld` will crash on startup with `fatal: slurmscriptd_init: Configured MailProg is invalid`. Create a stub script that SLURM can call without error:

```bash
sudo tee /usr/local/bin/slurm-no-mail << 'EOF'
#!/bin/sh
exit 0
EOF
sudo chmod +x /usr/local/bin/slurm-no-mail
```

> This stub silently discards all job notification emails. If you later want real email alerts, install an MTA (e.g. `postfix`) and update `MailProg` in `slurm.conf` to point to `/usr/bin/mail`.

### 10.5 Create slurm.conf on pi-node0

> **Script:** `initial/head-node/09-slurm-conf.sh`

Use `proctrack/linuxproc` and `task/affinity` only (cgroups disabled — see §10.6). `RealMemory=15000` matches measured free memory on these Pi 5 16 GB nodes.

```bash
sudo tee /etc/slurm/slurm.conf << 'EOF'
# Cluster identity
ClusterName=picluster
SlurmctldHost=pi-node0

# Authentication
AuthType=auth/munge
CryptoType=crypto/munge

# Scheduling
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory

# Process tracking
ProctrackType=proctrack/linuxproc
TaskPlugin=task/affinity

# MPI default
MpiDefault=pmix

# Mail notifications (no-op stub — Pi OS Lite has no mail agent)
MailProg=/usr/local/bin/slurm-no-mail

# Logging
SlurmctldDebug=info
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdDebug=info
SlurmdLogFile=/var/log/slurm/slurmd.log

# Timeouts
SlurmctldTimeout=300
SlurmdTimeout=300
InactiveLimit=0
MinJobAge=300
KillWait=30
Waittime=0

# State persistence
StateSaveLocation=/var/spool/slurm/ctld
SlurmdSpoolDir=/var/spool/slurm/d

# PID files
SlurmctldPidFile=/var/run/slurmctld.pid
SlurmdPidFile=/var/run/slurmd.pid

# Ports
SlurmctldPort=6817
SlurmdPort=6818

# Return down nodes to service automatically
ReturnToService=2

# Node definitions (adjust RealMemory to actual available MB)
NodeName=pi-node0 NodeAddr=192.168.129.36 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN
NodeName=pi-node1 NodeAddr=192.168.129.37 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN
NodeName=pi-node2 NodeAddr=192.168.129.38 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN
NodeName=pi-node3 NodeAddr=192.168.129.39 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN

# Partition (all 4 nodes available)
PartitionName=compute Nodes=pi-node[0-3] Default=YES MaxTime=INFINITE State=UP
EOF
```

> **Tip:** Replace `RealMemory=15000` with the actual value from `free -m` on your nodes (minus a small safety margin if needed).

### 10.6 Create cgroup.conf on all nodes

> **Scripts:** `initial/head-node/10-slurm-cgroup-conf.sh` · `initial/compute-node/06-slurm-cgroup-conf.sh`

Keep cgroups **disabled** on all nodes (matches the working live cluster with `proctrack/linuxproc`):

```bash
sudo tee /etc/slurm/cgroup.conf << 'EOF'
CgroupPlugin=disabled
CgroupAutomount=yes
ConstrainCores=no
ConstrainRAMSpace=no
ConstrainDevices=no
EOF
```

### 10.7 Distribute slurm.conf to all nodes

> **Script:** `initial/head-node/11-distribute-slurm-conf.sh`

Requires §5.1 (admin NOPASSWD) and §7 (passwordless SSH). Copy via `/tmp` then install (workers cannot write `/etc/slurm` over plain scp as admin without sudo):

```bash
# From pi-node0:
for node in pi-node1 pi-node2 pi-node3; do
    scp /etc/slurm/slurm.conf admin@$node:/tmp/slurm.conf
    scp /etc/slurm/cgroup.conf admin@$node:/tmp/cgroup.conf

    ssh admin@$node '
        sudo install -o root -g root -m 644 /tmp/slurm.conf  /etc/slurm/slurm.conf &&
        sudo install -o root -g root -m 644 /tmp/cgroup.conf /etc/slurm/cgroup.conf &&
        rm -f /tmp/slurm.conf /tmp/cgroup.conf
    '
done
```

### 10.8 Start SLURM services

> **Script coverage:** none — start daemons manually.

#### Run slurmctld as root (required)

Privilege mixing between the `slurm` package user and remote/admin operations can prevent `slurmctld` from starting cleanly. Override the unit on **pi-node0**:

```bash
sudo systemctl edit slurmctld.service
```

Add:

```ini
[Service]
User=root
Group=root
```

This writes `/etc/systemd/system/slurmctld.service.d/override.conf`. Then reload and start:

```bash
sudo systemctl daemon-reload
```

On **pi-node0** (controller + compute):

```bash
sudo systemctl enable --now slurmctld
sudo systemctl enable --now slurmd
```

On **pi-node1, pi-node2, pi-node3** (compute only):

```bash
sudo systemctl enable --now slurmd
```

---

## 11. Verifying the Cluster

Run these from **pi-node0** as `admin`:

```bash
# List partition and node states
sinfo

# Expected output:
# PARTITION  AVAIL  TIMELIMIT  NODES  STATE  NODELIST
# compute*   up     infinite   4      idle   pi-node[0-3]

# Show detailed node info
scontrol show nodes

# Run a test job on 1 node
srun --ntasks=1 hostname

# Run across all 4 nodes
srun --ntasks=4 --nodes=4 hostname

# Submit a batch job
cat > /tmp/test.sh << 'SCRIPT'
#!/bin/bash
#SBATCH --job-name=hello
#SBATCH --ntasks=4
#SBATCH --nodes=4
#SBATCH --output=/shared/scratch/hello_%j.out

srun hostname
SCRIPT

sbatch /tmp/test.sh
squeue         # watch the job
cat /shared/scratch/hello_*.out
```

If nodes appear in `drain` or `down` state:

```bash
sudo scontrol update NodeName=pi-node[0-3] State=RESUME
```

---

## 12. OpenMPI Installation

> **Script coverage:** none — install on all nodes manually.

Install OpenMPI **on all nodes**:

```bash
sudo apt install openmpi-bin openmpi-common libopenmpi-dev -y
```

Verify:

```bash
mpirun --version
which mpicc mpirun mpiexec
```

### 12.1 Disable IPv6 for OpenMPI (required)

Dual-stack TCP caused communication problems with OpenMPI on this cluster. Prefer IPv4 only:

- For `srun` / batch scripts, export: `OMPI_MCA_btl_tcp_disable_family=6`
- For direct `mpirun`: add `-mca btl_tcp_disable_family 6`

See [Open MPI issue discussion](https://github.com/open-mpi/ompi/issues/14079#issuecomment-4754197853).

---

## 13. Running MPI Jobs with C/C++

### 13.1 Hello World in C

Create `hello_mpi.c` in `/shared/scratch/`:

```c
#include <mpi.h>
#include <stdio.h>

int main(int argc, char *argv[]) {
    MPI_Init(&argc, &argv);

    int world_size, world_rank;
    MPI_Comm_size(MPI_COMM_WORLD, &world_size);
    MPI_Comm_rank(MPI_COMM_WORLD, &world_rank);

    char hostname[256];
    gethostname(hostname, sizeof(hostname));

    printf("Hello from rank %d of %d on %s\n", world_rank, world_size, hostname);

    MPI_Finalize();
    return 0;
}
```

Compile on **pi-node0** (binary goes to shared storage):

```bash
cd /shared/scratch
mpicc hello_mpi.c -o hello_mpi
```

### 13.2 SLURM batch script for C MPI job

```bash
cat > /shared/scratch/run_hello_mpi.sh << 'EOF'
#!/bin/bash
#SBATCH --job-name=hello_mpi_c
#SBATCH --nodes=4
#SBATCH --ntasks=16              # 4 tasks per node × 4 nodes
#SBATCH --ntasks-per-node=4
#SBATCH --output=/shared/scratch/hello_mpi_%j.out
#SBATCH --error=/shared/scratch/hello_mpi_%j.err
#SBATCH --time=00:05:00

export OMPI_MCA_btl_tcp_disable_family=6
srun /shared/scratch/hello_mpi
EOF

sbatch /shared/scratch/run_hello_mpi.sh
```

### 13.3 Pi estimation example in C++ (MPI collective)

```cpp
// pi_mpi.cpp - Monte Carlo Pi estimation using MPI
#include <mpi.h>
#include <iostream>
#include <random>
#include <cmath>

int main(int argc, char* argv[]) {
    MPI_Init(&argc, &argv);

    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    long long local_count = 1000000;
    long long local_inside = 0;

    std::mt19937_64 rng(42 + rank);
    std::uniform_real_distribution<double> dist(0.0, 1.0);

    for (long long i = 0; i < local_count; ++i) {
        double x = dist(rng);
        double y = dist(rng);
        if (x*x + y*y <= 1.0) ++local_inside;
    }

    long long global_inside = 0;
    long long global_count = 0;
    MPI_Reduce(&local_inside, &global_inside, 1, MPI_LONG_LONG, MPI_SUM, 0, MPI_COMM_WORLD);
    MPI_Reduce(&local_count,  &global_count,  1, MPI_LONG_LONG, MPI_SUM, 0, MPI_COMM_WORLD);

    if (rank == 0) {
        double pi_estimate = 4.0 * (double)global_inside / (double)global_count;
        std::cout << "Estimated Pi = " << pi_estimate
                  << " (using " << size << " ranks, " << global_count << " points)\n";
    }

    MPI_Finalize();
    return 0;
}
```

```bash
cd /shared/scratch
mpic++ pi_mpi.cpp -o pi_mpi -O2
```

Batch script:

```bash
cat > /shared/scratch/run_pi.sh << 'EOF'
#!/bin/bash
#SBATCH --job-name=pi_mpi
#SBATCH --nodes=4
#SBATCH --ntasks=16
#SBATCH --ntasks-per-node=4
#SBATCH --output=/shared/scratch/pi_%j.out
#SBATCH --time=00:02:00

export OMPI_MCA_btl_tcp_disable_family=6
srun /shared/scratch/pi_mpi
EOF

sbatch /shared/scratch/run_pi.sh
```

---

## 14. Running MPI Jobs with Python (mpi4py)

### 14.1 Install mpi4py on all nodes

```bash
sudo apt install python3-mpi4py python3-pip -y
# Or via pip (Avoid if possible!):
pip3 install mpi4py --break-system-packages
```

### 14.2 Hello World in Python (mpi4py)

```python
# /shared/scratch/hello_mpi.py
import os
from mpi4py import MPI

comm = MPI.COMM_WORLD
rank = comm.Get_rank()
size = comm.Get_size()
hostname = os.uname()[1]

print(f"Hello from rank {rank} of {size} on {hostname}")

comm.Barrier()
```

### 14.3 SLURM batch script for Python MPI job

```bash
cat > /shared/scratch/run_hello_mpi_py.sh << 'EOF'
#!/bin/bash
#SBATCH --job-name=hello_mpi_py
#SBATCH --nodes=4
#SBATCH --ntasks=16
#SBATCH --ntasks-per-node=4
#SBATCH --output=/shared/scratch/hello_py_%j.out
#SBATCH --error=/shared/scratch/hello_py_%j.err
#SBATCH --time=00:05:00

export OMPI_MCA_btl_tcp_disable_family=6
srun python3 /shared/scratch/hello_mpi.py
EOF

sbatch /shared/scratch/hello_mpi_py.sh
```

### 14.4 Scatter / Gather example in Python

```python
# /shared/scratch/scatter_gather.py
from mpi4py import MPI
import numpy as np

comm = MPI.COMM_WORLD
rank = comm.Get_rank()
size = comm.Get_size()

# Root process sends chunks of an array to each rank
if rank == 0:
    data = np.arange(size * 4, dtype='f')   # [0,1,2,...,4*size-1]
    chunks = [data[i*4:(i+1)*4] for i in range(size)]
else:
    chunks = None

local_data = comm.scatter(chunks, root=0)
local_result = local_data ** 2   # each rank squares its chunk

results = comm.gather(local_result, root=0)

if rank == 0:
    all_results = np.concatenate(results)
    print("Squared array:", all_results)
```

> **REMARK: Avoid installing packages for dependencies on the system's python3 interpreter! It is not recommended.** 
>  * Use a virtual environment instead!
>  * The `user` does not need have root privileges to create the virtual environment.
>  * The virtual environment is created in the shared storage and is available to all nodes.

### 14.5 Create a virtual environment to install dependencies

As `admin`, install virtualenv from debian package on head node:
```bash
sudo apt install virtualenv -y
```

Create a virtual environment that includes mpi4py and other dependencies:
```bash
virtualenv /shared/software/venv-mpi
```

Activate the virtual environment and install numpy:
```bash
source /shared/software/venv-mpi/bin/activate
pip install -U pip
pip install numpy mpi4py
deactivate
```

### Use it in SLURM jobs
```bash
cat > /shared/scratch/run_scatter_gather.sh << 'EOF'
#!/bin/bash
#SBATCH --ntasks=4
#SBATCH --output=/shared/scratch/job_%j.out

source /shared/software/venv-mpi/bin/activate
export OMPI_MCA_btl_tcp_disable_family=6
srun python /shared/scratch/scatter_gather.py
EOF

sbatch /shared/scratch/run_scatter_gather.sh
```

---

## 15. SLURM Job Management Cheatsheet

### Submit & Monitor

| Command | Description |
|---------|-------------|
| `sbatch job.sh` | Submit batch job |
| `srun --ntasks=4 cmd` | Run interactively across nodes |
| `squeue` | List queued/running jobs |
| `squeue -u user` | Jobs for a specific user |
| `scancel <jobid>` | Cancel a job |
| `sinfo` | Node and partition status |
| `sinfo -N -l` | Per-node detailed status |

### Job Information

| Command | Description |
|---------|-------------|
| `scontrol show job <id>` | Detailed job info |
| `scontrol show nodes` | All node details |
| `sacct -j <id>` | Job accounting after completion |
| `sacct -u user --format=JobID,JobName,State,Elapsed` | User job history |

### Node Management

| Command | Description |
|---------|-------------|
| `scontrol update NodeName=pi-node1 State=DRAIN Reason="maintenance"` | Drain a node |
| `scontrol update NodeName=pi-node1 State=RESUME` | Resume a drained node |
| `scontrol update NodeName=pi-node[0-3] State=RESUME` | Resume all nodes |

### Useful SBATCH Directives

```bash
#SBATCH --job-name=mytest          # Job name
#SBATCH --nodes=4                  # Number of nodes
#SBATCH --ntasks=16                # Total MPI tasks
#SBATCH --ntasks-per-node=4       # Tasks per node
#SBATCH --cpus-per-task=1         # Threads per task
#SBATCH --mem-per-cpu=2G          # Memory per CPU
#SBATCH --time=01:00:00           # Wall time HH:MM:SS
#SBATCH --output=job_%j.out       # stdout (%j = job ID)
#SBATCH --error=job_%j.err        # stderr
#SBATCH --partition=compute        # Partition name
```

---

## 16. Known Caveats & Troubleshooting

Operational caveats discovered during the first manual bring-up are summarized here (formerly tracked in `caveats_found.md`).

### Operational (required for a working cluster)

| Issue | Cause / Fix |
|-------|-------------|
| Head cannot run remote `sudo` / install confs | Configure passwordless SSH (§7) **and** `admin ALL=(ALL) NOPASSWD: ALL` in `/etc/sudoers.d/cluster-admin` on workers (§5.1 / `02-admin-sudoers.sh`). Limited sudoers command lists were insufficient. |
| `/etc/hosts` resets after reboot | Disable cloud-init: `sudo touch /etc/cloud/cloud-init.disabled` (§4.4). |
| `slurmctld` fails or has privilege errors | Run controller as root: `sudo systemctl edit slurmctld.service` with `User=root` / `Group=root` (§10.8). |
| OpenMPI hangs or fails over dual-stack | Disable IPv6 family: `export OMPI_MCA_btl_tcp_disable_family=6` for `srun`, or `-mca btl_tcp_disable_family 6` for `mpirun` (§12.1). |

### Hardware

| Issue | Cause / Fix |
|-------|-------------|
| Pi won't power on via PoE | Switch port may not be 802.3at. Confirm GS305EPP port is PoE+. Use a lower-numbered port (they have PoE priority). |
| Pi powers on but NVMe not detected | Check HAT seating on PCIe FPC connector. Some HATs require the locking clip to be fully closed. Run `lspci` to see if NVMe appears. |
| I/O errors in `dmesg` at PCIe Gen 3 | Revert to Gen 2: remove `dtparam=pciex1_gen=3` from config.txt |
| Do not connect USB-C while PoE active | Will damage the board. Always use PoE as the sole power source with these HATs. |
| Thermal throttling during MPI jobs | Verify active cooler is spinning. Check `vcgencmd measure_temp`. |

### OS & Network

| Issue | Cause / Fix |
|-------|-------------|
| Nodes cannot resolve each other by name | Ensure `/etc/hosts` entries are correct on all nodes. Disable cloud-init (§4.4) so they are not overwritten. |
| SSH asks for password between nodes | Re-run `ssh-copy-id` / `02-ssh-users.sh`. Check `~/.ssh/authorized_keys` permissions (must be `600`). |
| NFS mount fails at boot | Add `_netdev` to fstab options so mount waits for network. |

### SLURM

| Issue | Cause / Fix |
|-------|-------------|
| Nodes stuck in `down` state | Check `slurmd` is running: `systemctl status slurmd`. Check `/var/log/slurm/slurmd.log`. Run `scontrol update NodeName=... State=RESUME`. |
| `error: Authentication failure` | MUNGE key mismatch. Re-copy `/etc/munge/munge.key` from pi-node0 to all nodes, then restart `munge` and `slurmd`. |
| `srun` hangs after job submission | MUNGE clock skew. Verify `chronyc tracking` shows clocks in sync (< 60 s offset). |
| Jobs fail with cgroup errors | This cluster uses `CgroupPlugin=disabled` and `proctrack/linuxproc`. Do not enable cgroup constraints unless you intentionally rework §10.5–10.6. |
| `slurm.conf` mismatch warning | slurm.conf must be **identical** on all nodes. Re-run `11-distribute-slurm-conf.sh`. |
| RealMemory mismatch | Run `scontrol show node pi-node0` and compare `RealMemory` to your slurm.conf. Adjust down slightly. |
| `MailProg is invalid` | Create `/usr/local/bin/slurm-no-mail` (§10.4 / `08-slurm-no-mail.sh`). |

### MPI

| Issue | Cause / Fix |
|-------|-------------|
| `mpirun` fails to launch on remote nodes | Ensure passwordless SSH is configured for the running user. |
| OpenMPI dual-stack / TCP issues | Use IPv4-only MCA flags (§12.1). |
| `mpi4py` import error | Install on all nodes: `pip3 install mpi4py --break-system-packages` |
| Tasks all run on one node | Use `srun` instead of `mpirun`, or pass `--hosts` / `--hostfile` to mpirun explicitly. With SLURM, `srun` is the preferred launcher — it reads `SLURM_*` env vars automatically. |
| PMIx error with `srun` | Add `MpiDefault=pmix` to `slurm.conf` and install `libpmix-dev`: `sudo apt install libpmix-dev -y` |

---

## Quick Reference: Boot Sequence Order

When setting up from scratch, always proceed in this order to avoid dependency issues:

1. Flash and boot all nodes from NVMe (§3)
2. Set hostnames and `/etc/hosts` on all nodes; disable cloud-init (§4)
3. Create users (`munge`, `slurm`, `user` UID 1002) with matching UID/GID on all nodes (`01-users.sh`)
4. Configure admin NOPASSWD sudo on compute nodes (`02-admin-sudoers.sh`)
5. Synchronise clocks (chrony) (§6)
6. Set up passwordless SSH (`02-ssh-users.sh`)
7. Configure NFS (USB + server on pi-node0, clients on others) (`03`–`05` head / `03` compute)
8. Configure MUNGE (fix perms / distribute key, start on all) (`06` head / `04` compute)
9. Install and configure SLURM (dirs, no-mail, conf, cgroup, distribute) (`07`–`11` head / `05`–`06` compute)
10. Override `slurmctld` to run as root; start `slurmctld` on pi-node0 and `slurmd` on all nodes (§10.8)
11. Install OpenMPI and mpi4py on all nodes; apply IPv6 MCA workaround (§12)
12. Test with `sinfo`, `srun hostname`, then MPI jobs

---

*Guide compiled June 2026; updated after initial bring-up caveats. Trixie release date: 21 Apr 2026. Always verify package names against the current Debian Trixie repositories as package names may differ slightly between releases.*
