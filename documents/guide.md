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
- Memory cgroup enforcement is **disabled by default** in Raspberry Pi OS Trixie. It must be explicitly enabled in the kernel command line (`cgroup_enable=memory`). As of kernel 6.12+, only cgroup v2 memory reporting is available; the legacy v1 `/proc/cgroups` interface is intentionally removed.
- The NETGEAR GS305EPP delivers up to **120 W total PoE budget** (30 W per port). A fully-loaded RPi5 with M.2 + PoE HAT draws approximately **15–20 W** per node, leaving comfortable headroom.

### 1.2 SLURM on Debian Trixie

- Debian Trixie ships **SLURM 24.11.5-4** in its official APT repository (`arm64` architecture supported). No compilation from source is required.
- The `slurm-wlm` metapackage installs `slurmctld`, `slurmd`, and `slurm-client` in one step.
- SLURM 24.x defaults to **cgroup v2** (`CgroupPlugin=autodetect`). On Debian Trixie (systemd 257+), delegation is handled by systemd automatically.
- The `slurm` and `munge` system users must have **identical UIDs and GIDs** across every node before packages are installed. The recommended approach is to pre-create these users with explicit IDs before running `apt install`.

### 1.3 NVMe Boot on Raspberry Pi 5

Key EEPROM requirements for third-party M.2 HATs:

| Setting | Value | Reason |
|---------|-------|--------|
| `BOOT_ORDER` | `0xf416` | Try NVMe (6) first, USB (1) last |
| `PCIE_PROBE` | `1` | Force PCIe bus scan before boot device selection |
| `dtparam=pciex1` | in `config.txt` | Enable the PCIe FFC interface |
| `dtparam=pciex1_gen=3` | in `config.txt` | Unlock Gen 3 speeds (~900 MB/s vs ~450 MB/s) |
| `cgroup_enable=memory` | in `cmdline.txt` | Enable memory cgroup for SLURM resource enforcement |

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
| Memory cgroup disabled by default | SLURM cannot enforce RAM limits | Add `cgroup_enable=memory` to `cmdline.txt` |
| `slurm`/`munge` UIDs differ across nodes | SLURM auth failures | Pre-create users with fixed UIDs before package install |
| MUNGE key permissions too open | `munged` refuses to start | Ensure `chmod 0400 /etc/munge/munge.key`, owner `munge:munge` |
| NFS mount hangs if NFS server not up | `slurmd` fails on compute nodes | Add `_netdev` option to fstab, use `nfs-client.target` ordering |
| PoE HAT fan not controlled by OS | Node runs hot | Install `rpi-eeprom` firmware update; enable fan control overlay |
| SLURM `slurm.conf` inconsistency | Jobs fail or are rejected | Copy **identical** `slurm.conf` to every node |
| USB SSD filesystem not labelled | Device node changes on reboot | Mount by UUID or label, not by `/dev/sda` |

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
| pi-node0  | 192.168.1.101  | Head node, SLURM controller, NFS server, compute |
| pi-node1  | 192.168.1.102  | Compute node                                   |
| pi-node2  | 192.168.1.103  | Compute node                                   |
| pi-node3  | 192.168.1.104  | Compute node                                   |

**Why pi-node0 also computes:** The RPi5 is powerful enough to run `slurmctld` without significantly impacting job performance. Reserving it exclusively as a controller wastes 4 cores and 16 GB of RAM. SLURM handles job scheduling gracefully even when the controller is under compute load.

**Alternative:** Reserve pi-node0 exclusively as controller if jobs regularly spike all 4 cores. The trade-off is 25% reduced cluster capacity.

### 2.3 Network Design

- **Subnet:** `192.168.1.0/24`
- **Static IPs:** Configured via NetworkManager (`nmcli`) — the default network manager in Raspberry Pi OS Trixie
- **Gateway:** Your home router (e.g., `192.168.1.1`) — only pi-node0 needs internet access for package installation; compute nodes reach the internet through the switch
- **DNS:** Cluster nodes resolve each other via `/etc/hosts` (no DNS server needed at this scale)
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
- Feature flags: `rpi5,arm64`

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

#### 1.5 Enable Memory cgroup

This is required for SLURM to enforce memory limits on jobs.

```bash
sudo nano /boot/firmware/cmdline.txt
```

**Append** (do not create a new line) to the existing single line:

```
cgroup_enable=memory
```

The complete line should look similar to:

```
console=serial0,115200 console=tty1 root=PARTUUID=xxxxxxxx-02 rootfstype=ext4 fsck.repair=yes rootwait quiet cgroup_enable=memory
```

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

sudo nano /mnt/nvme-boot/cmdline.txt
# (Append cgroup_enable=memory)

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
  ipv4.addresses "192.168.1.101/24" \
  ipv4.gateway "192.168.1.1" \
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
192.168.1.101   pi-node0
192.168.1.102   pi-node1
192.168.1.103   pi-node2
192.168.1.104   pi-node3
EOF
```

> Replace `127.0.1.1   pi-node0` with the appropriate hostname on each node.

**Verify:**

```bash
ping -c 2 pi-node1
# PING pi-node1 (192.168.1.102): 56 data bytes
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
allow 192.168.1.0/24

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
echo "UUID=${USB_UUID}  /mnt/storage  ext4  defaults,noatime  0  2" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo mount /mnt/storage
```

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
/mnt/storage/shared  192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)

# Shared home directory for user account
/mnt/storage/home/user  192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)
EOF

sudo systemctl enable --now nfs-kernel-server
sudo exportfs -ra
```

**Verify exports:**

```bash
sudo exportfs -v
# /mnt/storage/shared  192.168.1.0/24(sync,wdelay,hide,no_subtree_check,...)
# /mnt/storage/home/user  192.168.1.0/24(...)

showmount -e pi-node0
# Export list for pi-node0:
# /mnt/storage/shared     192.168.1.0/24
# /mnt/storage/home/user  192.168.1.0/24
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
# Create SLURM state and log directories
sudo mkdir -p /var/spool/slurmctld   # Controller state (pi-node0 only, but harmless on all)
sudo mkdir -p /var/spool/slurmd      # Compute node state
sudo mkdir -p /var/log/slurm

sudo chown slurm:slurm /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
sudo chmod 0755 /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
```

#### 9.2 Create slurm.conf

Create this file on **pi-node0** first, then distribute to all nodes.

```bash
sudo tee /etc/slurm/slurm.conf > /dev/null << 'EOF'
# =========================================================
# SLURM Configuration for pi-cluster
# Generated for Raspberry Pi 5 cluster (4 nodes x 4 cores x 16 GB)
# SLURM 24.11.5 on Debian Trixie
# =========================================================

# Cluster identity
ClusterName=pi-cluster
SlurmctldHost=pi-node0

# Authentication
AuthType=auth/munge
CredType=cred/munge

# Communication
SlurmctldPort=6817
SlurmdPort=6818
ReturnAddrBindAddr=no

# Users and paths
SlurmUser=slurm
SlurmdUser=root
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmdSpoolDir=/var/spool/slurmd
StateSaveLocation=/var/spool/slurmctld

# Logging levels (set to 3 for production, increase for debugging)
SlurmctldDebug=info
SlurmdDebug=info

# Process tracking — required for cgroup enforcement
ProctrackType=proctrack/cgroup
TaskPlugin=task/affinity,task/cgroup

# Scheduling
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory

# Job accounting (flat file, no database needed)
JobAcctGatherType=jobacct_gather/cgroup
AccountingStorageType=accounting_storage/none

# Timers
InactiveLimit=0
KillWait=30
MinJobAge=300
SlurmctldTimeout=120
SlurmdTimeout=300
Waittime=0

# Priority (simple for small cluster)
PriorityType=priority/basic

# Topology
TopologyPlugin=topology/none

# Prolog/Epilog (none for basic setup)
# Prolog=/etc/slurm/prolog.sh
# Epilog=/etc/slurm/epilog.sh

# =========================================================
# NODE DEFINITIONS
# Raspberry Pi 5: 4x ARM Cortex-A76, 16 GB RAM
# RealMemory=15000 reserves 1 GB for OS
# =========================================================
NodeName=pi-node0 NodeAddr=192.168.1.101 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN Features=rpi5,headnode
NodeName=pi-node1 NodeAddr=192.168.1.102 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN Features=rpi5
NodeName=pi-node2 NodeAddr=192.168.1.103 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN Features=rpi5
NodeName=pi-node3 NodeAddr=192.168.1.104 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN Features=rpi5

# =========================================================
# PARTITIONS
# =========================================================

# All partition: submits to all 4 nodes including head node
PartitionName=all Nodes=pi-node[0-3] Default=YES MaxTime=INFINITE State=UP

# Compute partition: submits only to dedicated compute nodes
PartitionName=compute Nodes=pi-node[1-3] Default=NO MaxTime=INFINITE State=UP

# Debug partition: one node, short jobs, useful for testing
PartitionName=debug Nodes=pi-node1 Default=NO MaxTime=00:30:00 State=UP
EOF
```

#### 9.3 Create cgroup.conf

```bash
sudo tee /etc/slurm/cgroup.conf > /dev/null << 'EOF'
# SLURM cgroup configuration for Raspberry Pi 5 / Debian Trixie
# Debian Trixie uses cgroup v2 (unified hierarchy)

# Let SLURM detect the cgroup version automatically
CgroupPlugin=autodetect

# Enable all available controllers in the cgroup tree
# Required on systemd-managed systems for proper delegation
EnableControllers=yes

# Resource enforcement
ConstrainCores=yes
ConstrainRAMSpace=yes
ConstrainSwapSpace=yes
ConstrainDevices=no

# Allow 0% swap (set to 0 to disable swap entirely for jobs)
AllowedSwapSpace=0

# MemSpecLimit reserves memory for system processes (MB)
# Jobs cannot use this memory
MemSpecLimit=512
EOF
```

#### 9.4 Distribute Configuration to All Nodes

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

#### 9.5 Start SLURM Services

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
# all*          up   infinite      4   idle  pi-node[0-3]
# compute       up   infinite      3   idle  pi-node[1-3]
# debug         up    0:30:00      1   idle  pi-node1

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
srun --nodes=1 hostname
# pi-node1  (or any available node)

# Submit a job spanning all nodes
srun --nodes=4 hostname
# pi-node0
# pi-node1
# pi-node2
# pi-node3

# Submit a batch job
cat > /tmp/test.sh << 'SCRIPT'
#!/bin/bash
#SBATCH --job-name=hello-cluster
#SBATCH --nodes=4
#SBATCH --ntasks=4
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
192.168.1.101   pi-node0
192.168.1.102   pi-node1
192.168.1.103   pi-node2
192.168.1.104   pi-node3
```

Replace `HOSTNAME_OF_THIS_NODE` with `pi-node0`, `pi-node1`, etc.

### 4.2 /etc/exports (pi-node0 only)

```
# NFS exports for pi-cluster
/mnt/storage/shared      192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)
/mnt/storage/home/user   192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)
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
allow 192.168.1.0/24
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
ClusterName=pi-cluster
SlurmctldHost=pi-node0
AuthType=auth/munge
CredType=cred/munge
SlurmctldPort=6817
SlurmdPort=6818
SlurmUser=slurm
SlurmdUser=root
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmdSpoolDir=/var/spool/slurmd
StateSaveLocation=/var/spool/slurmctld
SlurmctldDebug=info
SlurmdDebug=info
ProctrackType=proctrack/cgroup
TaskPlugin=task/affinity,task/cgroup
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory
JobAcctGatherType=jobacct_gather/cgroup
AccountingStorageType=accounting_storage/none
InactiveLimit=0
KillWait=30
MinJobAge=300
SlurmctldTimeout=120
SlurmdTimeout=300
Waittime=0
PriorityType=priority/basic
TopologyPlugin=topology/none
NodeName=pi-node0 NodeAddr=192.168.1.101 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN Features=rpi5,headnode
NodeName=pi-node1 NodeAddr=192.168.1.102 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN Features=rpi5
NodeName=pi-node2 NodeAddr=192.168.1.103 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN Features=rpi5
NodeName=pi-node3 NodeAddr=192.168.1.104 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN Features=rpi5
PartitionName=all Nodes=pi-node[0-3] Default=YES MaxTime=INFINITE State=UP
PartitionName=compute Nodes=pi-node[1-3] Default=NO MaxTime=INFINITE State=UP
PartitionName=debug Nodes=pi-node1 Default=NO MaxTime=00:30:00 State=UP
```

### 4.7 /etc/slurm/cgroup.conf (All Nodes — Identical)

```
CgroupPlugin=autodetect
EnableControllers=yes
ConstrainCores=yes
ConstrainRAMSpace=yes
ConstrainSwapSpace=yes
ConstrainDevices=no
AllowedSwapSpace=0
MemSpecLimit=512
```

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

# Unmount NFS on compute nodes
for node in pi-node1 pi-node2 pi-node3; do
  ssh admin@${node} "sudo umount /shared /home/user"
done

# Stop NFS server
sudo systemctl stop nfs-kernel-server

# Sync all data
sync

# Shutdown all nodes
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
srun --ntasks=1 --partition=debug echo "Hello from $(hostname)"

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

Install OpenMPI first:

```bash
# On all nodes
sudo apt install -y openmpi-bin openmpi-common libopenmpi-dev
```

```bash
cat > /tmp/mpi-test.sh << 'EOF'
#!/bin/bash
#SBATCH --job-name=mpi-test
#SBATCH --nodes=4
#SBATCH --ntasks=16
#SBATCH --ntasks-per-node=4
#SBATCH --time=00:05:00
#SBATCH --output=/shared/mpi-%j.out

module list 2>/dev/null || true
mpirun hostname
EOF

# Create a simple MPI hello world
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
#SBATCH --time=00:02:00
#SBATCH --output=/shared/mpi-hello-%j.out

srun /shared/hello_mpi
EOF

sbatch /tmp/mpi-hello.sh
```

---

## 8. Troubleshooting Guide

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

**Diagnosis:** Check GS305EPP port LEDs. Each port supports max 30W. PoE class must match.

**Fix:** Ensure GS305EPP has IEEE 802.3af/at PoE enabled (check web interface at switch IP). Most RPi5 PoE HATs require 802.3at (PoE+) for full power.

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

#### SLURM Cannot Enforce Memory Limits

**Symptoms:** Jobs use more RAM than requested; `ConstrainRAMSpace` has no effect.

**Fix:** Memory cgroup is not enabled.
```bash
# Check on the affected node:
cat /proc/cmdline | grep cgroup_enable
# Should contain: cgroup_enable=memory

# If not present, add to cmdline.txt:
sudo nano /boot/firmware/cmdline.txt
# Append: cgroup_enable=memory
sudo reboot
```

#### slurmctld: "Communication error" from compute nodes

**Symptoms:** Compute nodes register but immediately show DOWN; logs show `munge` errors.

```bash
# On a compute node:
sudo journalctl -u slurmd -n 50 | grep -i munge

# Check munge UID matches
id munge   # Compare across all nodes - must be identical
```

**Fix:** If munge UIDs differ, remove and recreate both `slurm` and `munge` users with explicit UIDs (requires reinstalling `munge` and `slurm-wlm` packages).

---

## 9. Future Improvements

### 9.1 Performance Optimizations

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

### 9.2 Software Stack Additions

- **Julia 1.11.1:** Install from the official Julia download page; not in Debian Trixie repos at this version.
- **Python 3.14:** Available in Debian Trixie (`python3`); install with `apt install python3 python3-pip python3-venv`.
- **OpenMPI 5.0.x:** Available via `apt install openmpi-bin libopenmpi-dev`.
- **CMake 3.28+:** Available via `apt install cmake`.
- **Lmod / Environment Modules:** For managing multiple software versions on shared storage.

### 9.3 Monitoring

- **Prometheus + Node Exporter:** Deploy on each node for real-time metrics.
- **Grafana:** Dashboard on pi-node0 for cluster health visualization.
- **SLURM accounting:** Enable `JobAcctGatherType=jobacct_gather/linux` and a SQLite/MySQL database for job history.

### 9.4 High Availability

- For production use, consider SLURM's `BackupController` option pointing to pi-node1. This provides controller failover if pi-node0 crashes.
- Use a DRBD-mirrored volume for `StateSaveLocation` between pi-node0 and pi-node1.

### 9.5 Security Hardening

- Enable `fail2ban` to block SSH brute-force attacks.
- Configure `ufw` firewall to allow only required ports (22, 6817, 6818, 2049, 111, 123).
- Rotate the MUNGE key periodically and use `scontrol reconfigure` after distributing the new key.
- Consider replacing MUNGE with `auth/jwt` for external user access (SLURM 24.x+).

### 9.6 Kubernetes Option

The same hardware can run a lightweight Kubernetes cluster (K3s) alongside or instead of SLURM. K3s has native support for RPi5 and Debian Trixie, and the cgroup configuration required for SLURM (`cgroup_enable=memory`) is identical to what K3s needs. The two schedulers should not run simultaneously on the same cluster.
