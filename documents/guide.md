# Raspberry Pi 5 SLURM Cluster — Deployment Guide

> **Author:** Manuel A. Diaz | **Cluster OS:** Raspberry Pi OS Lite 64-bit (Debian Trixie) | **SLURM:** 24.11.5 | **Date:** June 2026

---

## Table of Contents

1. [Research Findings](#1-research-findings)
2. [Architecture Decisions](#2-architecture-decisions)
3. [Deployment Guide](#3-deployment-guide)
4. [Configuration Files](#4-configuration-files)
5. [Automation Scripts](#5-automation-scripts)
6. [Operations Guide](#6-operations-guide)
7. [Validation Procedures](#7-validation-procedures)
8. [Troubleshooting Guide](#8-troubleshooting-guide)
9. [Future Improvements](#9-future-improvements)

---

## 1. Research Findings

### 1.1 Raspberry Pi 5 Cluster Projects

Community cluster builds confirm that the RPi5 is a capable compute node for small HPC workloads. Key lessons learned from existing builds:

- The RPi5 PCIe bus requires **explicit enabling** in `config.txt` when using non-official M.2 HAT+ adapters. The official Raspberry Pi M.2 HAT+ enables PCIe automatically, but third-party PoE + M.2 combo HATs do not.
- PCIe Gen 3 mode (`dtparam=pciex1_gen=3`) is **unofficial but stable** with most commercial NVMe drives including the Transcend 256 GB M.2 2242. It roughly doubles sequential throughput compared to Gen 2.
- **Critical PoE caveat:** When a PoE HAT is supplying power, **never connect the USB-C port** on the Pi 5 to another power supply at the same time. Dual power can damage the board or HAT. PoE is the sole power source.
- The NETGEAR GS305EPP delivers up to **120 W total PoE budget** (30 W per port). Lower-numbered ports have PoE priority if the budget is contested. A fully-loaded RPi5 with M.2 + PoE HAT draws approximately **15–20 W** per node under heavy load.
- Memory cgroup enforcement is **disabled by default** in Raspberry Pi OS Trixie. This cluster’s **live SLURM config does not use cgroup job isolation** (`CgroupPlugin=disabled`). Enabling `cgroup_enable=memory` is optional and reserved for a future cgroup-enforcement path (see Future Improvements).

### 1.2 SLURM on Debian Trixie

- Debian Trixie ships **SLURM 24.11.5-4** in its official APT repository (`arm64` architecture supported). No compilation from source is required.
- The `slurm-wlm` metapackage installs `slurmctld`, `slurmd`, and `slurm-client` in one step.
- The **live working configuration** uses `ProctrackType=proctrack/linuxproc`, `TaskPlugin=task/affinity`, and `CgroupPlugin=disabled` (cgroup job isolation deferred). Install `libpmix-dev` because `MpiDefault=pmix`.
- Raspberry Pi OS Lite has **no mail agent**. Without a stub at `/usr/local/bin/slurm-no-mail`, `slurmctld` fatals with `Configured MailProg is invalid`.
- On this hardware, run **`slurmctld` as root** via a systemd override (`User=root` / `Group=root`); the package `slurm` user can hit privilege errors on start.
- The `slurm` and `munge` system users must have **identical UIDs and GIDs** across every node before packages are installed. The recommended approach is to pre-create these users with explicit IDs before running `apt install`.

### 1.3 NVMe Boot on Raspberry Pi 5

Key EEPROM requirements for third-party M.2 HATs:

| Setting | Value | Reason |
|---------|-------|--------|
| `BOOT_ORDER` | `0xf416` | Try NVMe (6) first, USB (1) last |
| `PCIE_PROBE` | `1` | Force PCIe bus scan before boot device selection |
| `dtparam=pciex1` | in `config.txt` | Enable the PCIe FFC interface |
| `dtparam=pciex1_gen=3` | in `config.txt` | Unlock Gen 3 speeds (~900 MB/s vs ~450 MB/s) |

**SD card fallback:** Using `BOOT_ORDER=0xf416` (NVMe first, SD last) allows recovery by re-inserting an SD card with a working OS image. Recommended for production.

### 1.4 MUNGE Authentication

- MUNGE is the **default and recommended** authentication mechanism for SLURM.
- A single `/etc/munge/munge.key` (1024 random bytes) must be **byte-identical** on every node.
- Credentials expire after 300 seconds by default — **clock synchronization is mandatory**. A drift of more than a few seconds between nodes will cause authentication failures.
- MUNGE provides **authentication, not encryption**. Messages are signed, not encrypted.
- The `munge` daemon must start **before** any SLURM daemon on every node.

### 1.5 Known Issues and Caveats

| Issue | Impact | Workaround |
|-------|--------|------------|
| NVMe invisible at boot without `PCIE_PROBE=1` | Node fails to boot from NVMe | Set `PCIE_PROBE=1` in EEPROM |
| USB-C connected while PoE active | Hardware damage | Use PoE as the sole power source |
| cloud-init rewrites `/etc/hosts` on reboot | Nodes lose name resolution | `sudo touch /etc/cloud/cloud-init.disabled` |
| `MailProg is invalid` | `slurmctld` crashes on start | Create `/usr/local/bin/slurm-no-mail` stub |
| `slurmctld` privilege errors | Controller fails to start | systemd override `User=root` / `Group=root` |
| OpenMPI dual-stack / IPv6 hangs | MPI jobs hang or fail | `OMPI_MCA_btl_tcp_disable_family=6` |
| PMIx missing | `srun` MPI errors | Install `libpmix-dev`; set `MpiDefault=pmix` |
| `slurm`/`munge` UIDs differ across nodes | SLURM auth failures | Pre-create users with fixed UIDs before package install |
| MUNGE key permissions too open | `munged` refuses to start | Ensure `chmod 0400 /etc/munge/munge.key`, owner `munge:munge` |
| NFS mount hangs if NFS server not up | Boot / jobs hang | Add `_netdev` (and soft mounts) to fstab |
| Power off pi-node0 while NFS still mounted | Stale NFS; workers hang | Unmount clients first; use `umount -l` if needed |
| PoE HAT fan not controlled by OS | Node runs hot | Install `rpi-eeprom` firmware update; enable fan control overlay |
| SLURM `slurm.conf` inconsistency | Jobs fail or are rejected | Copy **identical** `slurm.conf` to every node |
| USB SSD device node changes on reboot | Mount fails | Mount by UUID; use `nofail` in fstab |

---

## 2. Architecture Decisions

### 2.1 Cluster Topology

```
Internet / Home Network
        │
   ┌────▼────────────────────────────────────────────────────┐
   │         NETGEAR GS305EPP (5-port PoE Gigabit)           │
   │  Port 1  │  Port 2  │  Port 3  │  Port 4  │  Port 5    │
   └────┬─────┴────┬─────┴────┬─────┴────┬─────┴────────────┘
        │          │          │          │
   ┌────▼───┐ ┌────▼───┐ ┌────▼───┐ ┌────▼───┐
   │pi-node0│ │pi-node1│ │pi-node2│ │pi-node3│
   │ Head + │ │Compute │ │Compute │ │Compute │
   │Compute │ │  Node  │ │  Node  │ │  Node  │
   │NFS Svr │ │        │ │        │ │        │
   └────────┘ └────────┘ └────────┘ └────────┘
   USB SSD
   /mnt/storage
```

### 2.2 Node Role Assignment

| Hostname  | IP Address     | Role                                           |
|-----------|----------------|------------------------------------------------|
| pi-node0  | 192.168.129.36  | Head node, SLURM controller, NFS server, compute |
| pi-node1  | 192.168.129.37  | Compute node                                   |
| pi-node2  | 192.168.129.38  | Compute node                                   |
| pi-node3  | 192.168.129.39  | Compute node                                   |

**Why pi-node0 also computes:** The RPi5 is powerful enough to run `slurmctld` without significantly impacting job performance. Reserving it exclusively as a controller wastes 4 cores and 16 GB of RAM. SLURM handles job scheduling gracefully even when the controller is under compute load.

**Alternative:** Reserve pi-node0 exclusively as controller if jobs regularly spike all 4 cores. The trade-off is 25% reduced cluster capacity.

### 2.3 Network Design

- **Subnet:** `192.168.129.0/24`
- **Static IPs:** Configured via NetworkManager (`nmcli`) — the default network manager in Raspberry Pi OS Trixie
- **Gateway:** Your LAN router (e.g., `192.168.128.1`) — only pi-node0 needs internet access for package installation; compute nodes reach the internet through the switch
- **DNS:** Cluster nodes resolve each other via `/etc/hosts` (no DNS server needed at this scale). **Disable cloud-init** after writing hosts so Raspberry Pi OS cannot rewrite `/etc/hosts` on reboot.
- **Why static IPs:** SLURM `slurm.conf` references hostnames; MUNGE requires consistent identity; NFS mounts must be stable across reboots

### 2.4 Storage Design

```
pi-node0 (NFS Server)
├── /dev/nvme0n1       — System OS (256 GB NVMe SSD)
└── /dev/sda1          — USB SSD (1 TB ext4)
    └── /mnt/storage
        ├── /mnt/storage/shared    → exported as /shared (all nodes)
        └── /mnt/storage/home      → exported as /home/user (all nodes)

pi-node1/2/3 (NFS Clients)
├── /dev/nvme0n1       — System OS (256 GB NVMe SSD)
├── /shared            — NFS mount from pi-node0:/mnt/storage/shared
└── /home/user         — NFS mount from pi-node0:/mnt/storage/home/user
```

**Why NFS over local storage for jobs:** SLURM jobs typically write output files that must be accessible from the submitting node. Without shared storage, users would have to manually copy files between nodes. NFS provides transparent access.

**Trade-off:** NFS adds latency. For I/O-intensive jobs, local NVMe scratch space (`/tmp` or a per-node `/scratch`) should be used instead. See [Future Improvements](#9-future-improvements).

### 2.5 Authentication Design

- **System users:** `admin` (UID auto, sudo) and `user` (UID auto, no sudo)
- **SLURM users:** `slurm` (UID 64002, GID 64002) — fixed to prevent conflicts
- **MUNGE users:** `munge` (UID 64003, GID 64003) — fixed to prevent conflicts
- **SSH:** Password-less SSH for `admin` user between all nodes (needed for cluster operations)

**Why fixed UIDs for slurm/munge:** These daemons communicate across nodes. If the UID is 64002 on pi-node0 and 64005 on pi-node1, file permission checks fail and authentication breaks. Creating them before package installation with explicit IDs prevents this.

### 2.6 SLURM Architecture

```
┌───────────────────────────────────────────────────────────┐
│  pi-node0 (Controller + Compute)                          │
│  ┌─────────────┐    ┌──────────────────────────────────┐  │
│  │  slurmctld  │    │  slurmd (NodeName=pi-node0)      │  │
│  │  (port 6817)│    │  (port 6818)                     │  │
│  └─────────────┘    └──────────────────────────────────┘  │
└───────────────────────────────────────────────────────────┘
           │ MUNGE-authenticated RPC
  ┌────────┼────────┐
  │        │        │
┌─▼──────┐ ┌─▼──────┐ ┌─▼──────┐
│slurmd  │ │slurmd  │ │slurmd  │
│pi-node1│ │pi-node2│ │pi-node3│
└────────┘ └────────┘ └────────┘
```

**Node hardware parameters:**
- CPUs: 4 (ARM Cortex-A76, 1 socket, 4 cores, 1 thread per core)
- RealMemory: 15000 MB (leaving ~1 GB for OS and system processes)
- Process tracking: `proctrack/linuxproc` (cgroups disabled in live config)
- Partition: single `compute` partition covering all four nodes
- `slurmctld` runs as **root** via systemd override; `MailProg` points at a no-op stub

---

## 3. Deployment Guide

> **Prerequisite:** You need one Raspberry Pi 5 with an SD card (any size) running Raspberry Pi OS Trixie Lite to start. Each Pi will boot from SD card initially, then be migrated to NVMe.
>
> **Perform all steps as root (`sudo -i`) unless stated otherwise.**

---

### Step 1: NVMe Boot Configuration

Perform this step on each Pi individually while booted from SD card.

#### 1.1 Flash Raspberry Pi OS Lite to SD Card

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) on your laptop. Select:
- OS: **Raspberry Pi OS Lite (64-bit)** — Debian Trixie, 21 April 2026 or newer
- Enable SSH, set username `admin` and a password in the imager's advanced options
- Write to SD card, insert into Pi, power on

#### 1.2 Update the System and EEPROM

```bash
sudo apt update && sudo apt full-upgrade -y
sudo rpi-eeprom-update
```

If an update is shown, apply it:

```bash
sudo rpi-eeprom-update -a
sudo reboot
```

Verify the EEPROM version after reboot:

```bash
sudo rpi-eeprom-update
# Should show: BOOTLOADER: up to date
```

#### 1.3 Enable PCIe and Configure Boot Order

Edit the EEPROM bootloader configuration:

```bash
sudo rpi-eeprom-config --edit
```

The editor opens `vi`. Modify the file to contain at minimum:

```ini
BOOT_UART=1
BOOT_ORDER=0xf416
PCIE_PROBE=1
```

`BOOT_ORDER=0xf416`: Tries NVMe (digit 6) first, USB (digit 4) second, SD card (digit 1) last. The `f` restarts the sequence. This allows SD card recovery.

Save and exit (`ESC :wq` in vi). The new configuration is written to the EEPROM.

#### 1.4 Enable PCIe in config.txt (Required for Third-Party HATs)

```bash
sudo nano /boot/firmware/config.txt
```

Add the following lines at the end of the file:

```ini
# Enable PCIe FFC interface (required for non-official M.2 HATs)
dtparam=pciex1

# Enable PCIe Gen 3 speed (unofficial but stable with Transcend drives)
dtparam=pciex1_gen=3

# Disable Bluetooth and Wi-Fi (cluster nodes use wired networking only)
dtoverlay=disable-bt
dtoverlay=disable-wifi
```

#### 1.5 Memory cgroup (optional — not used by live config)

The live cluster uses `CgroupPlugin=disabled` and `proctrack/linuxproc`. **Do not** add `cgroup_enable=memory` to `cmdline.txt` for the default path.

If you later enable cgroup job isolation (Future Improvements), append `cgroup_enable=memory` to `/boot/firmware/cmdline.txt` (single line) and reboot.

#### 1.6 Verify NVMe is Detected

Reboot and verify the NVMe drive is visible:

```bash
sudo reboot
# After reboot:
lsblk
# Expected output includes: nvme0n1 (NVMe drive)

sudo nvme list
# Shows: /dev/nvme0n1  Transcend 256GB  ...
```

If the drive is not detected:
- Check physical seating of the M.2 card in the HAT
- Verify `dtparam=pciex1` is in `config.txt`
- Verify `PCIE_PROBE=1` is in EEPROM config

#### 1.7 Install OS on NVMe

Use the Raspberry Pi Imager CLI (available on the running Pi):

```bash
# Install imager if not present
sudo apt install -y rpi-imager

# Write OS to NVMe (this will ERASE the NVMe drive)
sudo rpi-imager --cli /path/to/2026-04-21-raspios-trixie-arm64-lite.img.xz /dev/nvme0n1
```

Or use `dd` from a downloaded image:

```bash
sudo dd if=2026-04-21-raspios-trixie-arm64-lite.img.xz of=/dev/nvme0n1 bs=4M status=progress conv=fsync
```

#### 1.8 Pre-configure the NVMe Boot Partition

Mount the NVMe boot partition and apply the same configuration:

```bash
sudo mkdir -p /mnt/nvme-boot
sudo mount /dev/nvme0n1p1 /mnt/nvme-boot

# Re-apply the config.txt changes on the NVMe partition
sudo nano /mnt/nvme-boot/config.txt
# (Add dtparam=pciex1, dtparam=pciex1_gen=3, dtoverlay=disable-bt, dtoverlay=disable-wifi)

# Do NOT append cgroup_enable=memory for the live (cgroups-disabled) path

# Enable SSH on first boot
sudo touch /mnt/nvme-boot/ssh

# Set user credentials (format: username:hashed-password)
# Generate hash: echo 'your-password' | openssl passwd -6 -stdin
echo 'admin:$6$YOUR_HASHED_PASSWORD' | sudo tee /mnt/nvme-boot/userconf.txt

sudo umount /mnt/nvme-boot
```

Remove the SD card and reboot. The Pi should boot from NVMe.

**Verify NVMe boot:**

```bash
findmnt /
# TARGET  SOURCE         FSTYPE OPTIONS
# /       /dev/nvme0n1p2 ext4   ...
```

---

### Step 2: Static Network Configuration

Raspberry Pi OS Trixie uses **NetworkManager** by default. Configure static IPs with `nmcli`.

Run on each node, replacing the IP for each node accordingly.

#### 2.1 Configure Static IP

```bash
# Get the connection name
nmcli connection show
# Typically: "Wired connection 1" or "eth0"

# Set static IP (adjust IP and hostname per node)
# On pi-node0:
sudo nmcli connection modify "Wired connection 1" \
  ipv4.method manual \
  ipv4.addresses "192.168.129.36/24" \
  ipv4.gateway "192.168.128.1" \
  ipv4.dns "8.8.8.8,8.8.4.4" \
  connection.autoconnect yes

sudo nmcli connection up "Wired connection 1"
```

#### 2.2 Set Hostname

```bash
# On pi-node0:
sudo hostnamectl set-hostname pi-node0

# On pi-node1:
sudo hostnamectl set-hostname pi-node1

# On pi-node2:
sudo hostnamectl set-hostname pi-node2

# On pi-node3:
sudo hostnamectl set-hostname pi-node3
```

#### 2.3 Configure /etc/hosts (All Nodes)

```bash
sudo tee /etc/hosts > /dev/null << 'EOF'
127.0.0.1       localhost
127.0.1.1       pi-node0

# Cluster nodes
192.168.129.36   pi-node0
192.168.129.37   pi-node1
192.168.129.38   pi-node2
192.168.129.39   pi-node3
EOF
```

> Replace `127.0.1.1   pi-node0` with the appropriate hostname on each node.

#### 2.4 Disable cloud-init (All Nodes)

Raspberry Pi OS may rewrite `/etc/hosts` on reboot via cloud-init. Disable it **after** hosts are correct:

```bash
sudo mkdir -p /etc/cloud
sudo touch /etc/cloud/cloud-init.disabled
```

**Verify:**

```bash
ping -c 2 pi-node1
# PING pi-node1 (192.168.129.37): 56 data bytes
```

---

### Step 3: User Accounts

Perform on **all nodes** in the same order to ensure consistent UIDs.

#### 3.1 Create System Users for SLURM and MUNGE

These users must be created with **identical UIDs and GIDs** before installing any packages.

```bash
# Create munge group and user
sudo groupadd --gid 64003 munge
sudo useradd --uid 64003 --gid 64003 --no-create-home --shell /usr/sbin/nologin munge

# Create slurm group and user
sudo groupadd --gid 64002 slurm
sudo useradd --uid 64002 --gid 64002 --no-create-home --shell /usr/sbin/nologin slurm
```

#### 3.2 Create the admin User

```bash
# The admin user is typically created by the OS installer.
# Verify it exists:
id admin

# If not present:
sudo useradd --create-home --shell /bin/bash --groups sudo admin
sudo passwd admin
```

#### 3.3 Create the user Account

```bash
sudo useradd --uid 2000 --create-home --shell /bin/bash user
sudo passwd user
```

Use UID 2000 so `user` has a consistent UID across all nodes — important when NFS-sharing `/home/user`.

**Verify:**

```bash
id munge
# uid=64003(munge) gid=64003(munge) groups=64003(munge)

id slurm
# uid=64002(slurm) gid=64002(slurm) groups=64002(slurm)

id user
# uid=2000(user) gid=2000(user) groups=2000(user)
```

---

### Step 4: SSH Configuration

#### 4.1 Harden SSH on All Nodes

```bash
sudo nano /etc/ssh/sshd_config.d/cluster.conf
```

```ini
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
X11Forwarding no
AllowUsers admin user
```

```bash
sudo systemctl restart ssh
```

#### 4.2 Set Up Password-less SSH for admin

Run on **pi-node0** only:

```bash
# Generate SSH key pair as admin user
ssh-keygen -t ed25519 -C "admin@pi-cluster" -f ~/.ssh/id_ed25519 -N ""

# Copy public key to all nodes (including self)
for node in pi-node0 pi-node1 pi-node2 pi-node3; do
  ssh-copy-id -i ~/.ssh/id_ed25519.pub admin@${node}
done
```

**Verify:**

```bash
for node in pi-node1 pi-node2 pi-node3; do
  ssh admin@${node} "hostname && uptime"
done
```

---

### Step 5: Base System Packages

Run on **all nodes**:

```bash
sudo apt update && sudo apt upgrade -y

sudo apt install -y \
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
  stress-ng
```

Run on **pi-node0 only** (additional packages for head node):

```bash
sudo apt install -y \
  nfs-kernel-server \
  slurm-wlm
```

Run on **pi-node1, pi-node2, pi-node3** (compute nodes):

```bash
sudo apt install -y \
  slurmd \
  slurm-client
```

---

### Step 6: Time Synchronization (Chrony)

Accurate time is **critical** for MUNGE. A drift of more than ~5 minutes between nodes causes authentication failures.

#### 6.1 Configure pi-node0 as Cluster NTP Server

```bash
sudo tee /etc/chrony/chrony.conf > /dev/null << 'EOF'
# Upstream NTP servers
pool 2.debian.pool.ntp.org iburst maxsources 4
pool time.cloudflare.com iburst maxsources 2

# Allow cluster nodes to sync from this node
allow 192.168.129.0/24

# Local clock as fallback (stratum 10 indicates low quality)
local stratum 10

# Logging
logdir /var/log/chrony
log measurements statistics tracking

# Important settings
makestep 1.0 3
rtcsync
driftfile /var/lib/chrony/drift
EOF

sudo systemctl enable --now chrony
```

#### 6.2 Configure Compute Nodes to Use pi-node0

Run on **pi-node1, pi-node2, pi-node3**:

```bash
sudo tee /etc/chrony/chrony.conf > /dev/null << 'EOF'
# Use cluster head node as primary NTP source
server pi-node0 iburst prefer

# Fallback to public servers if head node unreachable
pool 2.debian.pool.ntp.org iburst maxsources 2

makestep 1.0 3
rtcsync
driftfile /var/lib/chrony/drift
logdir /var/log/chrony
EOF

sudo systemctl enable --now chrony
```

**Verify:**

```bash
chronyc sources -v
# Should show pi-node0 (on compute nodes) or public NTP servers with * (selected)

chronyc tracking
# Should show: System time: 0.0000... seconds fast/slow
```

---

### Step 7: NFS Shared Storage

#### 7.1 Prepare the USB SSD (pi-node0 only)

```bash
# Identify the USB SSD
lsblk
# Find the 1 TB USB drive, typically /dev/sda

# Get the UUID (do NOT rely on /dev/sda which may change)
sudo blkid /dev/sda1
# /dev/sda1: UUID="xxxx-xxxx-xxxx" TYPE="ext4"

# If the drive is new, partition and format it:
sudo parted /dev/sda --script mklabel gpt
sudo parted /dev/sda --script mkpart primary ext4 0% 100%
sudo mkfs.ext4 -L cluster-storage /dev/sda1

# Create mount point
sudo mkdir -p /mnt/storage
```

**Add to /etc/fstab on pi-node0** (use UUID for stability):

```bash
USB_UUID=$(sudo blkid -s UUID -o value /dev/sda1)
echo "UUID=${USB_UUID}  /mnt/storage  ext4  defaults,noatime,nofail  0  2" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo mount /mnt/storage
```

Use `nofail` so a missing USB disk does not block boot.
**Create shared directory structure:**

```bash
sudo mkdir -p /mnt/storage/shared
sudo mkdir -p /mnt/storage/home/user
sudo chown -R user:user /mnt/storage/home/user
sudo chmod 755 /mnt/storage/shared
sudo chmod 755 /mnt/storage/home

# Verify
df -h /mnt/storage
# /dev/sda1  932G  ... /mnt/storage
```

#### 7.2 Configure NFS Exports (pi-node0 only)

```bash
sudo tee /etc/exports > /dev/null << 'EOF'
# NFS exports for pi-cluster
# Format: directory  client(options)

# Shared scratch/data space for all cluster nodes
/mnt/storage/shared  192.168.129.0/24(rw,sync,no_subtree_check,no_root_squash)

# Shared home directory for user account
/mnt/storage/home/user  192.168.129.0/24(rw,sync,no_subtree_check,no_root_squash)
EOF

sudo systemctl enable --now nfs-kernel-server
sudo exportfs -ra
```

**Verify exports:**

```bash
sudo exportfs -v
# /mnt/storage/shared  192.168.129.0/24(sync,wdelay,hide,no_subtree_check,...)
# /mnt/storage/home/user  192.168.129.0/24(...)

showmount -e pi-node0
# Export list for pi-node0:
# /mnt/storage/shared     192.168.129.0/24
# /mnt/storage/home/user  192.168.129.0/24
```

#### 7.3 Mount NFS on Compute Nodes (pi-node1, 2, 3)

```bash
# Create mount points
sudo mkdir -p /shared
sudo mkdir -p /home/user

# Add to /etc/fstab (use _netdev to wait for network before mounting)
sudo tee -a /etc/fstab > /dev/null << 'EOF'

# NFS mounts from pi-node0
pi-node0:/mnt/storage/shared      /shared     nfs  defaults,_netdev,soft,timeo=30,retrans=3  0  0
pi-node0:/mnt/storage/home/user   /home/user  nfs  defaults,_netdev,soft,timeo=30,retrans=3  0  0
EOF

sudo systemctl daemon-reload
sudo mount -a
```

**Verify:**

```bash
df -h | grep nfs
# pi-node0:/mnt/storage/shared     932G  ...  /shared
# pi-node0:/mnt/storage/home/user  932G  ...  /home/user

# Write test
touch /shared/test-from-$(hostname)
ls /shared/
# test-from-pi-node1  (visible from all nodes)
```

---

### Step 8: MUNGE Configuration

MUNGE must be configured **before** SLURM is started.

#### 8.1 Generate MUNGE Key (pi-node0 only)

```bash
# Generate a cryptographically random key
sudo dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key

# Set correct ownership and permissions
sudo chown munge:munge /etc/munge/munge.key
sudo chmod 0400 /etc/munge/munge.key

# Verify
ls -la /etc/munge/munge.key
# -r-------- 1 munge munge 1024 ... /etc/munge/munge.key
```

#### 8.2 Distribute MUNGE Key to All Nodes

Run on **pi-node0** as admin:

```bash
for node in pi-node1 pi-node2 pi-node3; do
  echo "Copying munge.key to ${node}..."
  sudo scp /etc/munge/munge.key admin@${node}:/tmp/munge.key
  ssh admin@${node} "sudo mv /tmp/munge.key /etc/munge/munge.key && \
    sudo chown munge:munge /etc/munge/munge.key && \
    sudo chmod 0400 /etc/munge/munge.key"
done
```

#### 8.3 Set MUNGE Directory Permissions (All Nodes)

```bash
sudo chown -R munge:munge /etc/munge /var/log/munge /var/lib/munge /run/munge
sudo chmod 0700 /etc/munge /var/log/munge /var/lib/munge
```

#### 8.4 Start MUNGE (All Nodes)

```bash
sudo systemctl enable --now munge
sudo systemctl status munge
# Active: active (running)
```

**Verify MUNGE across nodes (from pi-node0):**

```bash
# Test local credential
munge -n | unmunge
# STATUS: Success (0)

# Test remote credential
munge -n | ssh pi-node1 unmunge
# STATUS: Success (0)

# Test all nodes
for node in pi-node0 pi-node1 pi-node2 pi-node3; do
  echo -n "${node}: "
  munge -n | ssh ${node} unmunge 2>&1 | grep STATUS
done
```

---

### Step 9: SLURM Installation and Configuration

#### 9.1 SLURM Directory Setup (All Nodes)

```bash
# Create SLURM state and log directories (paths match live picluster)
sudo mkdir -p /var/spool/slurm/ctld   # Controller state (pi-node0)
sudo mkdir -p /var/spool/slurm/d      # Compute node state
sudo mkdir -p /var/log/slurm

sudo chown slurm:slurm /var/spool/slurm/ctld /var/spool/slurm/d /var/log/slurm
sudo chmod 0755 /var/spool/slurm/ctld /var/spool/slurm/d /var/log/slurm
```

#### 9.2 Create the no-op mail stub (pi-node0)

Pi OS Lite has no MTA. Without this, `slurmctld` fatals with `Configured MailProg is invalid`:

```bash
sudo tee /usr/local/bin/slurm-no-mail > /dev/null << 'EOF'
#!/bin/sh
exit 0
EOF
sudo chmod +x /usr/local/bin/slurm-no-mail
```

#### 9.3 Create slurm.conf

Create this file on **pi-node0** first, then distribute to all nodes. Matches the live working cluster (`picluster`): cgroups disabled, PMIx, CryptoType=crypto/munge.

```bash
sudo tee /etc/slurm/slurm.conf > /dev/null << 'EOF'
# =============================================================================
# slurm.conf — picluster (Raspberry Pi 5 x4, Debian Trixie, SLURM 24.11.5)
# Must be IDENTICAL on all nodes.
# =============================================================================

ClusterName=picluster
SlurmctldHost=pi-node0

AuthType=auth/munge
CryptoType=crypto/munge

SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory

# Live path: no cgroup job isolation
ProctrackType=proctrack/linuxproc
TaskPlugin=task/affinity

MpiDefault=pmix
MailProg=/usr/local/bin/slurm-no-mail

SlurmctldDebug=info
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdDebug=info
SlurmdLogFile=/var/log/slurm/slurmd.log

SlurmctldTimeout=300
SlurmdTimeout=300
InactiveLimit=0
MinJobAge=300
KillWait=30
Waittime=0

StateSaveLocation=/var/spool/slurm/ctld
SlurmdSpoolDir=/var/spool/slurm/d

SlurmctldPidFile=/var/run/slurmctld.pid
SlurmdPidFile=/var/run/slurmd.pid

SlurmctldPort=6817
SlurmdPort=6818

ReturnToService=2

NodeName=pi-node0 NodeAddr=192.168.129.36 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN
NodeName=pi-node1 NodeAddr=192.168.129.37 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN
NodeName=pi-node2 NodeAddr=192.168.129.38 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN
NodeName=pi-node3 NodeAddr=192.168.129.39 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN

PartitionName=compute Nodes=pi-node[0-3] Default=YES MaxTime=INFINITE State=UP
EOF
```

#### 9.4 Create cgroup.conf

```bash
sudo tee /etc/slurm/cgroup.conf > /dev/null << 'EOF'
# Live cluster: cgroup enforcement disabled (proctrack/linuxproc)
CgroupPlugin=disabled
CgroupAutomount=yes
ConstrainCores=no
ConstrainRAMSpace=no
ConstrainDevices=no
EOF
```

#### 9.5 Distribute Configuration to All Nodes

```bash
for node in pi-node1 pi-node2 pi-node3; do
  echo "Copying SLURM config to ${node}..."
  sudo scp /etc/slurm/slurm.conf admin@${node}:/tmp/slurm.conf
  sudo scp /etc/slurm/cgroup.conf admin@${node}:/tmp/cgroup.conf
  ssh admin@${node} "sudo mv /tmp/slurm.conf /etc/slurm/slurm.conf && \
    sudo mv /tmp/cgroup.conf /etc/slurm/cgroup.conf && \
    sudo chown slurm:slurm /etc/slurm/slurm.conf /etc/slurm/cgroup.conf && \
    sudo chmod 644 /etc/slurm/slurm.conf /etc/slurm/cgroup.conf"
done
```

#### 9.6 Run slurmctld as root (pi-node0)

Privilege mixing can prevent `slurmctld` from starting cleanly. Override the unit:

```bash
sudo systemctl edit slurmctld.service
```

Add:

```ini
[Service]
User=root
Group=root
```

Then:

```bash
sudo systemctl daemon-reload
```

#### 9.7 Start SLURM Services

On **pi-node0** (controller + compute):

```bash
sudo systemctl enable --now slurmctld
sudo systemctl enable --now slurmd
```

On **pi-node1, pi-node2, pi-node3** (compute only):

```bash
sudo systemctl enable --now slurmd
```

**Verify all nodes registered:**

```bash
# On pi-node0:
sinfo
# PARTITION  AVAIL  TIMELIMIT  NODES  STATE  NODELIST
# compute*      up   infinite      4   idle  pi-node[0-3]

scontrol show nodes
# NodeName=pi-node0 ... State=IDLE ...
```

---

### Step 10: Cluster Validation

```bash
# Check SLURM is fully operational
sinfo -N -l
# All nodes should show IDLE state

# Submit a test job
srun --nodes=1 --partition=compute hostname

# Submit a job spanning all nodes
srun --nodes=4 --partition=compute hostname

# Submit a batch job
cat > /tmp/test.sh << 'SCRIPT'
#!/bin/bash
#SBATCH --job-name=hello-cluster
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --partition=compute
#SBATCH --output=/shared/hello-%j.out

srun hostname
date
SCRIPT

sbatch /tmp/test.sh
# Submitted batch job 1

# Monitor the job
squeue
watch squeue   # press Ctrl+C when done

# View output
cat /shared/hello-1.out
```

---

## 4. Configuration Files

### 4.1 /etc/hosts (All Nodes)

```
127.0.0.1       localhost
127.0.1.1       HOSTNAME_OF_THIS_NODE

# Cluster nodes
192.168.129.36   pi-node0
192.168.129.37   pi-node1
192.168.129.38   pi-node2
192.168.129.39   pi-node3
```

Replace `HOSTNAME_OF_THIS_NODE` with `pi-node0`, `pi-node1`, etc.

### 4.2 /etc/exports (pi-node0 only)

```
# NFS exports for pi-cluster
/mnt/storage/shared      192.168.129.0/24(rw,sync,no_subtree_check,no_root_squash)
/mnt/storage/home/user   192.168.129.0/24(rw,sync,no_subtree_check,no_root_squash)
```

**Option explanations:**
- `rw`: Read-write access
- `sync`: Write to disk before acknowledging (safer than `async` for job data)
- `no_subtree_check`: Improves reliability, required when files may be renamed during access
- `no_root_squash`: Allows root on compute nodes to write to NFS shares (needed for SLURM job management)

### 4.3 /etc/chrony/chrony.conf (pi-node0)

```
pool 2.debian.pool.ntp.org iburst maxsources 4
pool time.cloudflare.com iburst maxsources 2
allow 192.168.129.0/24
local stratum 10
makestep 1.0 3
rtcsync
driftfile /var/lib/chrony/drift
logdir /var/log/chrony
log measurements statistics tracking
```

### 4.4 /etc/chrony/chrony.conf (Compute Nodes)

```
server pi-node0 iburst prefer
pool 2.debian.pool.ntp.org iburst maxsources 2
makestep 1.0 3
rtcsync
driftfile /var/lib/chrony/drift
logdir /var/log/chrony
```

### 4.5 /etc/munge/munge.key

This file is **binary** — it is generated on pi-node0 with:

```bash
sudo dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key
sudo chown munge:munge /etc/munge/munge.key
sudo chmod 0400 /etc/munge/munge.key
```

The same file is copied byte-for-byte to all other nodes. It must never be committed to version control or placed in a world-readable location.

### 4.6 /etc/slurm/slurm.conf (All Nodes — Identical)

```
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
SlurmctldDebug=info
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdDebug=info
SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmctldTimeout=300
SlurmdTimeout=300
InactiveLimit=0
MinJobAge=300
KillWait=30
Waittime=0
StateSaveLocation=/var/spool/slurm/ctld
SlurmdSpoolDir=/var/spool/slurm/d
SlurmctldPidFile=/var/run/slurmctld.pid
SlurmdPidFile=/var/run/slurmd.pid
SlurmctldPort=6817
SlurmdPort=6818
ReturnToService=2
NodeName=pi-node0 NodeAddr=192.168.129.36 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN
NodeName=pi-node1 NodeAddr=192.168.129.37 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN
NodeName=pi-node2 NodeAddr=192.168.129.38 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN
NodeName=pi-node3 NodeAddr=192.168.129.39 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN
PartitionName=compute Nodes=pi-node[0-3] Default=YES MaxTime=INFINITE State=UP
```

### 4.7 /etc/slurm/cgroup.conf (All Nodes — Identical)

```
CgroupPlugin=disabled
CgroupAutomount=yes
ConstrainCores=no
ConstrainRAMSpace=no
ConstrainDevices=no
```

Also required on pi-node0:

- `/usr/local/bin/slurm-no-mail` — stub script (`exit 0`)
- `/etc/systemd/system/slurmctld.service.d/override.conf` — `User=root` / `Group=root`
---

## 5. Automation Scripts

The `scripts/` directory contains production-ready Bash scripts that automate all the above steps.

```
scripts/
├── head-node/
│   ├── 01-base-system.sh       Base packages, system configuration
│   ├── 02-network.sh           Static IP, hostname, /etc/hosts
│   ├── 03-users.sh             Create munge/slurm/admin/user accounts
│   ├── 04-chrony.sh            NTP server configuration
│   ├── 05-nfs-server.sh        USB SSD mount, NFS export setup
│   ├── 06-munge.sh             Generate and distribute munge.key
│   └── 07-slurm-controller.sh  SLURM installation, config, service start
└── compute-node/
    ├── 01-base-system.sh       Base packages, system configuration
    ├── 02-network.sh           Static IP, hostname, /etc/hosts
    ├── 03-users.sh             Create munge/slurm/user accounts
    ├── 04-chrony.sh            NTP client configuration
    ├── 05-nfs-client.sh        NFS mount setup
    ├── 06-munge.sh             Receive and install munge.key
    └── 07-slurm-node.sh        SLURM compute node setup

scripts/ops/
├── cluster-startup.sh          Start all services in correct order
├── cluster-shutdown.sh         Drain jobs, shutdown cluster
└── cluster-reboot.sh           Rolling reboot of cluster nodes
```

**Usage on head node:**
```bash
cd scripts/head-node/
sudo bash 01-base-system.sh
sudo bash 02-network.sh
# ... etc.
```

**Usage on compute nodes** (run after head node is configured):
```bash
cd scripts/compute-node/
sudo bash 01-base-system.sh
sudo bash 02-network.sh
# ... etc.
```

---

## 6. Operations Guide

### 6.1 Cluster Startup

```bash
# On pi-node0 (starts all services via the ops script):
sudo /home/admin/scripts/ops/cluster-startup.sh
```

Manual startup order:

```bash
# 1. On pi-node0: start MUNGE
sudo systemctl start munge

# 2. On pi-node0: mount USB storage
sudo mount /mnt/storage

# 3. On pi-node0: start NFS
sudo systemctl start nfs-kernel-server

# 4. On compute nodes: start MUNGE, mount NFS
for node in pi-node1 pi-node2 pi-node3; do
  ssh admin@${node} "sudo systemctl start munge && sudo mount -a"
done

# 5. On pi-node0: start SLURM controller
sudo systemctl start slurmctld

# 6. On all nodes: start SLURM daemon
for node in pi-node0 pi-node1 pi-node2 pi-node3; do
  ssh admin@${node} "sudo systemctl start slurmd"
done

# 7. Verify cluster health
sinfo
```

### 6.2 Cluster Shutdown

> **Never power off pi-node0 while worker nodes still have NFS mounts.** Clients will hang on file I/O and may need a hard reboot. If a worker is stuck with a stale mount, run `sudo umount -l /shared` (and `/home/user` if applicable) for a lazy unmount.

```bash
# Drain all jobs before shutdown
sudo scontrol update NodeName=pi-node[0-3] State=DRAIN Reason="Scheduled shutdown"

# Wait for running jobs to finish
watch squeue   # Wait until empty

# Stop SLURM on compute nodes
for node in pi-node1 pi-node2 pi-node3; do
  ssh admin@${node} "sudo systemctl stop slurmd"
done

# Stop SLURM controller
sudo systemctl stop slurmctld

# Unmount NFS on compute nodes FIRST
for node in pi-node1 pi-node2 pi-node3; do
  ssh admin@${node} "sudo umount /shared /home/user || sudo umount -l /shared /home/user"
done

# Stop NFS server
sudo systemctl stop nfs-kernel-server

# Sync all data
sync

# Shutdown compute nodes, then the head node last
for node in pi-node1 pi-node2 pi-node3; do
  ssh admin@${node} "sudo shutdown -h now"
done
sudo shutdown -h now
```
### 6.3 Rolling Reboot

```bash
# Reboot compute nodes one at a time, keeping cluster available
for node in pi-node1 pi-node2 pi-node3; do
  echo "Draining ${node}..."
  sudo scontrol update NodeName=${node} State=DRAIN Reason="Rolling reboot"

  # Wait until no jobs run on this node
  while squeue -w ${node} | grep -q RUNNING; do
    sleep 30
  done

  echo "Rebooting ${node}..."
  ssh admin@${node} "sudo reboot"
  sleep 60

  # Wait for node to come back
  until ping -c1 ${node} &>/dev/null; do sleep 5; done
  sleep 30

  # Re-enable node
  sudo scontrol update NodeName=${node} State=RESUME
  echo "${node} back online"
done
```

### 6.4 Useful SLURM Commands

| Command | Description |
|---------|-------------|
| `sinfo` | Cluster node status summary |
| `sinfo -N -l` | Detailed per-node status |
| `squeue` | Running and pending jobs |
| `squeue -u user` | Jobs for specific user |
| `scancel <jobid>` | Cancel a job |
| `sbatch job.sh` | Submit a batch job |
| `srun --nodes=2 hostname` | Run an interactive command on 2 nodes |
| `scontrol show job <id>` | Detailed job information |
| `scontrol show node pi-node1` | Detailed node information |
| `scontrol update NodeName=pi-node1 State=RESUME` | Bring a drained node back online |
| `scontrol reconfigure` | Reload slurm.conf without restart |

---

## 7. Validation Procedures

### 7.1 MUNGE Validation

```bash
# Local encode/decode
munge -n | unmunge
# STATUS: Success (0)

# Remote validation from pi-node0
for node in pi-node0 pi-node1 pi-node2 pi-node3; do
  echo -n "Munge test to ${node}: "
  munge -n | ssh ${node} unmunge 2>&1 | grep "STATUS:"
done

# Expect: STATUS: Success (0) for all nodes
```

### 7.2 NFS Validation

```bash
# From pi-node0
showmount -e pi-node0

# From compute nodes
df -h | grep nfs
mount | grep nfs

# Write test
echo "NFS write test from $(hostname)" > /shared/nfs-test-$(hostname).txt

# Read from another node
ssh pi-node1 "cat /shared/nfs-test-pi-node0.txt"

# Performance test
dd if=/dev/zero of=/shared/dd-test bs=1M count=512 oflag=direct
# Expect: ~50–100 MB/s over Gigabit Ethernet
```

### 7.3 SLURM Validation

```bash
# Cluster status
sinfo
scontrol show partition
scontrol show nodes

# Test 1: Single-task job
srun --ntasks=1 --partition=compute echo "Hello from $(hostname)"

# Test 2: Multi-node parallel job
srun --nodes=4 --ntasks-per-node=1 hostname

# Test 3: Interactive job
srun --pty --nodes=1 /bin/bash
# (opens a shell on a compute node, exit to return)

# Test 4: Batch job
cat > /tmp/batch-test.sh << 'EOF'
#!/bin/bash
#SBATCH --job-name=validation
#SBATCH --nodes=4
#SBATCH --ntasks=16
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=512M
#SBATCH --time=00:05:00
#SBATCH --output=/shared/validation-%j.out
#SBATCH --error=/shared/validation-%j.err

echo "=== Job ${SLURM_JOB_ID} on $(hostname) ==="
echo "Start: $(date)"
srun hostname
echo "End: $(date)"
EOF

sbatch /tmp/batch-test.sh
watch squeue
cat /shared/validation-*.out
```

### 7.4 CPU Stress Test

```bash
cat > /tmp/stress-test.sh << 'EOF'
#!/bin/bash
#SBATCH --job-name=stress-test
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --cpus-per-task=4
#SBATCH --mem-per-cpu=1G
#SBATCH --time=00:10:00
#SBATCH --output=/shared/stress-%j.out

echo "=== CPU Stress Test on $(hostname) at $(date) ==="
srun --ntasks=1 --cpus-per-task=4 stress-ng --cpu 4 --timeout 300s --metrics-brief
EOF

sbatch /tmp/stress-test.sh
```

Monitor temperatures during the test:

```bash
# On each node (in another terminal)
watch -n 1 'vcgencmd measure_temp && cat /sys/class/thermal/thermal_zone0/temp'
```

### 7.5 MPI Test (OpenMPI)

Install OpenMPI and PMIx on **all nodes** (`MpiDefault=pmix` in `slurm.conf`):

```bash
sudo apt install -y openmpi-bin openmpi-common libopenmpi-dev libpmix-dev
```

**Required:** Dual-stack TCP caused OpenMPI hangs on this cluster. Prefer IPv4 only:

- For `srun` / batch scripts: `export OMPI_MCA_btl_tcp_disable_family=6`
- For direct `mpirun`: add `-mca btl_tcp_disable_family 6`

Prefer **`srun`** over bare `mpirun` under SLURM (it reads `SLURM_*` environment variables automatically).

```bash
# Create a simple MPI hello world on shared storage
cat > /shared/hello_mpi.c << 'CEOF'
#include <mpi.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char* argv[]) {
    int rank, size;
    char hostname[256];
    MPI_Init(&argc, &argv);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);
    gethostname(hostname, sizeof(hostname));
    printf("Hello from rank %d of %d on %s\n", rank, size, hostname);
    MPI_Finalize();
    return 0;
}
CEOF

mpicc /shared/hello_mpi.c -o /shared/hello_mpi

cat > /tmp/mpi-hello.sh << 'EOF'
#!/bin/bash
#SBATCH --job-name=mpi-hello
#SBATCH --nodes=4
#SBATCH --ntasks=16
#SBATCH --ntasks-per-node=4
#SBATCH --partition=compute
#SBATCH --time=00:02:00
#SBATCH --output=/shared/mpi-hello-%j.out

export OMPI_MCA_btl_tcp_disable_family=6
srun /shared/hello_mpi
EOF

sbatch /tmp/mpi-hello.sh
```

---

## 8. Troubleshooting Guide

### 8.0 Operational Caveats (bring-up)

| Issue | Cause / Fix |
|-------|-------------|
| `/etc/hosts` resets after reboot | Disable cloud-init: `sudo touch /etc/cloud/cloud-init.disabled` |
| `MailProg is invalid` / `slurmctld` crash | Create `/usr/local/bin/slurm-no-mail` stub (`exit 0`) |
| `slurmctld` privilege errors | systemd override: `User=root` / `Group=root` |
| OpenMPI hang / dual-stack | `export OMPI_MCA_btl_tcp_disable_family=6` (or `-mca btl_tcp_disable_family 6`) |
| PMIx errors with `srun` | `MpiDefault=pmix` in `slurm.conf` + `apt install libpmix-dev` |
| Cgroup / `ConstrainRAMSpace` errors | Live config has **cgroups disabled**; do not enable unless intentionally reworking (Future Improvements) |
| USB-C connected while PoE active | Hardware damage risk — use PoE as the sole power source |
| NFS stale / hang when head powered off | Unmount clients first; `sudo umount -l /shared` if needed |
| GS305EPP port has no PoE | Prefer lower-numbered ports (PoE priority); confirm 802.3at |

### 8.1 Raspberry Pi 5 Hardware Issues

#### NVMe Not Detected at Boot

**Symptoms:** `lsblk` shows no NVMe device; fan runs at full speed; OS never loads.

**Diagnosis:**
```bash
# Boot from SD card and check:
sudo dmesg | grep -i pcie
sudo dmesg | grep -i nvme
```

**Fixes:**
1. Verify `dtparam=pciex1` is in `/boot/firmware/config.txt` on both SD card AND NVMe partitions.
2. Verify `PCIE_PROBE=1` is in EEPROM config (`sudo rpi-eeprom-config`).
3. Check the M.2 card is fully seated in the HAT slot (requires gentle but firm pressure).
4. Try removing `dtparam=pciex1_gen=3` — some drives only work at Gen 2.

#### Fan Running at Maximum Speed

**Symptoms:** Loud fan even at idle after boot from NVMe.

**Cause:** The OS did not take control of thermal management before the fan control was handed off.

**Fix:**
```bash
# Ensure the correct thermal overlay is loaded:
sudo nano /boot/firmware/config.txt
# Add: dtoverlay=rpi5-fan-shim  (if using standard fan)
# OR verify the PoE HAT fan overlay is configured
```

#### PoE HAT Not Providing Power

**Symptoms:** Pi powers on from SD card but not from PoE switch.

**Diagnosis:** Check GS305EPP port LEDs. Each port supports max 30W. PoE class must match. Lower-numbered ports have PoE priority.

**Fix:** Ensure GS305EPP has IEEE 802.3af/at PoE enabled (check web interface at switch IP). Most RPi5 PoE HATs require 802.3at (PoE+) for full power.

#### Dual Power (USB-C + PoE)

**Never** connect the Pi 5 USB-C power port while the PoE HAT is supplying power. Dual power can damage the board or HAT. Use PoE as the sole power source with these HATs.
### 8.2 NVMe Boot Caveats

#### PARTUUID Mismatch After Cloning

**Symptoms:** Kernel panic at boot: `VFS: Cannot open root device`.

**Fix:**
```bash
# Check PARTUUID
sudo blkid /dev/nvme0n1p2
# Get the actual PARTUUID and update cmdline.txt:
sudo mount /dev/nvme0n1p1 /mnt
sudo nano /mnt/cmdline.txt
# Update: root=PARTUUID=<actual-uuid>
sudo umount /mnt
```

#### Boot Hangs at Rainbow Screen

**Symptoms:** Rainbow screen (GPU test pattern) then nothing.

**Fix:** EEPROM `BOOT_ORDER` does not include NVMe (digit 6). Re-run `sudo rpi-eeprom-config --edit`.

### 8.3 Time Synchronization Issues

#### MUNGE Returns "Expired Credential"

**Symptoms:** `munge -n | unmunge` returns `STATUS: Expired credential (16)` on remote node.

**Diagnosis:**
```bash
chronyc tracking   # On failing node
# Check: System time: X seconds fast/slow
# If > 300 seconds: munge TTL exceeded
```

**Fix:**
```bash
# Force time sync on the lagging node
sudo chronyc makestep
sudo systemctl restart munge
```

#### Chrony Not Syncing

```bash
# Check sources
chronyc sources -v

# Force manual sync
sudo chronyd -q 'pool 2.debian.pool.ntp.org iburst'

# Verify NTP can reach pi-node0
ping pi-node0
telnet pi-node0 123   # Check NTP port is open
```

### 8.4 MUNGE Issues

#### munged Refuses to Start

**Common causes:**

```bash
# Check the service status
journalctl -u munge -n 50

# Fix 1: Wrong permissions on munge.key
sudo chown munge:munge /etc/munge/munge.key
sudo chmod 0400 /etc/munge/munge.key

# Fix 2: Wrong directory permissions
sudo chown munge:munge /etc/munge /var/lib/munge /var/log/munge /run/munge
sudo chmod 0700 /etc/munge /var/lib/munge /var/log/munge

# Fix 3: Socket directory not writable by munge
sudo mkdir -p /run/munge
sudo chown munge:munge /run/munge
sudo chmod 0755 /run/munge
```

#### MUNGE Key Mismatch

**Symptoms:** `STATUS: Invalid credential (13)` when testing cross-node.

```bash
# Compare MD5 hashes - must be identical on all nodes
for node in pi-node0 pi-node1 pi-node2 pi-node3; do
  echo -n "${node}: "
  ssh admin@${node} "sudo md5sum /etc/munge/munge.key" 2>/dev/null
done
# All lines must show the same hash
```

**Fix:** Re-distribute the key from pi-node0:
```bash
sudo scp /etc/munge/munge.key admin@pi-node1:/tmp/munge.key
ssh admin@pi-node1 "sudo mv /tmp/munge.key /etc/munge/munge.key && \
  sudo chown munge:munge /etc/munge/munge.key && \
  sudo chmod 0400 /etc/munge/munge.key && \
  sudo systemctl restart munge"
```

### 8.5 NFS Issues

#### NFS Mount Hangs at Boot

**Symptoms:** Node takes 90+ seconds to boot; `mount -a` hangs.

**Fix:** Ensure `_netdev` option is in `/etc/fstab` and NFS dependencies are correct:
```bash
# In fstab, use:
pi-node0:/mnt/storage/shared  /shared  nfs  defaults,_netdev,soft,timeo=30,retrans=3  0  0
```

The `soft` option causes the mount to return an error after `timeo*retrans` timeout instead of hanging forever. This is important for cluster resilience.

#### NFS Stale File Handle

```bash
# Force unmount and remount
sudo umount -l /shared
sudo mount /shared
```

#### NFS Permission Denied

```bash
# Check exports on server
sudo exportfs -v

# Check NFS server logs
sudo journalctl -u nfs-kernel-server -n 50

# Verify client IP is in the allowed subnet
showmount -e pi-node0
```

### 8.6 SLURM Issues

#### Node Shows "DOWN" After Restart

**Symptoms:** `sinfo` shows `pi-node1 down*`.

**Fix:**
```bash
# Check why the node went down
scontrol show node pi-node1 | grep Reason

# Check slurmd log on the node
ssh admin@pi-node1 "sudo journalctl -u slurmd -n 100"

# After fixing the underlying issue:
sudo scontrol update NodeName=pi-node1 State=RESUME
```

Common reasons:
- `Not responding` — `slurmd` not running; start it: `sudo systemctl start slurmd`
- `Low RealMemory` — `RealMemory` in `slurm.conf` is higher than actual RAM; reduce it
- `slurm.conf inconsistency` — the file on this node differs from the controller; re-copy and `scontrol reconfigure`

#### Jobs Stay Pending

```bash
# Check why job is pending
scontrol show job <jobid> | grep Reason
squeue -j <jobid> -o "%R"
```

Common reasons:
- `Resources` — not enough free CPUs/memory; wait or reduce job requirements
- `Priority` — other jobs have higher priority
- `PartitionNodeLimit` — requested more nodes than partition allows
- `BadConstraints` — requested feature (`--constraint=...`) not available on any node

#### SLURM cgroup / memory limit errors

**Symptoms:** Jobs fail with cgroup errors, or `ConstrainRAMSpace` has no effect.

**Live path:** This cluster uses `CgroupPlugin=disabled` and `proctrack/linuxproc`. Cgroup errors usually mean a node still has an old `slurm.conf` / `cgroup.conf` that enables cgroups. Re-copy the live configs and restart `slurmd`.

**Optional future path:** To enable cgroup memory enforcement later, see Future Improvements (§9.1) — that recipe requires `cgroup_enable=memory` in `cmdline.txt` and a different `cgroup.conf`.

#### slurmctld: "Communication error" from compute nodes

**Symptoms:** Compute nodes register but immediately show DOWN; logs show `munge` errors.

```bash
# On a compute node:
sudo journalctl -u slurmd -n 50 | grep -i munge

# Check munge UID matches
id munge   # Compare across all nodes - must be identical
```

**Fix:** If munge UIDs differ, remove and recreate both `slurm` and `munge` users with explicit UIDs (requires reinstalling `munge` and `slurm-wlm` packages).

#### MailProg is invalid

**Symptoms:** `slurmctld` fails with `fatal: ... Configured MailProg is invalid`.

**Fix:** Create the stub:

```bash
sudo tee /usr/local/bin/slurm-no-mail >/dev/null <<'EOF'
#!/bin/sh
exit 0
EOF
sudo chmod +x /usr/local/bin/slurm-no-mail
sudo systemctl restart slurmctld
```

---

## 9. Future Improvements

### 9.1 Optional: enable cgroup v2 job isolation

The live cluster intentionally keeps cgroups disabled. To enforce memory/CPU limits later:

1. Append `cgroup_enable=memory` to `/boot/firmware/cmdline.txt` on all nodes and reboot.
2. Change `slurm.conf` to `ProctrackType=proctrack/cgroup` and `TaskPlugin=task/affinity,task/cgroup`.
3. Set `cgroup.conf` to `CgroupPlugin=autodetect` with `ConstrainCores=yes` / `ConstrainRAMSpace=yes` (and related options).
4. Distribute configs and restart `slurmctld` / `slurmd`.

### 9.2 Performance Optimizations

- **PCIe Gen 3:** Already enabled with `dtparam=pciex1_gen=3`. Benchmark with `fio` to verify actual throughput vs Gen 2 baseline.
- **CPU governor:** Switch to `performance` governor for consistent latency:
  ```bash
  echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
  ```
- **NFS tuning:** Increase `rsize`/`wsize` mount options to `1048576` for large file transfers:
  ```
  nfs defaults,_netdev,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2
  ```
- **Local scratch space:** For I/O-intensive jobs, configure per-node `/scratch` on the local NVMe to avoid NFS bottleneck. Add to `slurm.conf`:
  ```
  TmpFS=/tmp
  ```

### 9.3 Software Stack Additions

- **Julia 1.11.1:** Install from the official Julia download page; not in Debian Trixie repos at this version.
- **Python 3.14:** Available in Debian Trixie (`python3`); install with `apt install python3 python3-pip python3-venv`.
- **OpenMPI 5.0.x:** Available via `apt install openmpi-bin libopenmpi-dev` (plus `libpmix-dev` for PMIx).
- **CMake 3.28+:** Available via `apt install cmake`.
- **Lmod / Environment Modules:** For managing multiple software versions on shared storage.

### 9.4 Monitoring

- **Prometheus + Node Exporter:** Deploy on each node for real-time metrics.
- **Grafana:** Dashboard on pi-node0 for cluster health visualization.
- **SLURM accounting:** Enable `JobAcctGatherType=jobacct_gather/linux` and a SQLite/MySQL database for job history.

### 9.5 High Availability

- For production use, consider SLURM's `BackupController` option pointing to pi-node1. This provides controller failover if pi-node0 crashes.
- Use a DRBD-mirrored volume for `StateSaveLocation` between pi-node0 and pi-node1.

### 9.6 Security Hardening

- Enable `fail2ban` to block SSH brute-force attacks.
- Configure `ufw` firewall to allow only required ports (22, 6817, 6818, 2049, 111, 123).
- Rotate the MUNGE key periodically and use `scontrol reconfigure` after distributing the new key.
- Consider replacing MUNGE with `auth/jwt` for external user access (SLURM 24.x+).

### 9.7 Kubernetes Option

The same hardware can run a lightweight Kubernetes cluster (K3s) alongside or instead of SLURM. K3s has native support for RPi5 and Debian Trixie; enabling memory cgroups (`cgroup_enable=memory`) is typically required for K3s, independent of this cluster’s SLURM cgroups-disabled path. The two schedulers should not run simultaneously on the same cluster.