# Automation Scripts

See the [deployment guide](../documents/guide.md) for full documentation.

Live config notes (as of the high-priority caveats sync):

- **No** `cgroup_enable=memory` in base-system scripts — live SLURM uses `CgroupPlugin=disabled` / `proctrack/linuxproc`
- `02-network.sh` writes `/etc/hosts` and creates `/etc/cloud/cloud-init.disabled`
- `05-nfs-server.sh` uses fstab `nofail` for the USB SSD
- `07-slurm-controller.sh` creates `/usr/local/bin/slurm-no-mail`, installs a `slurmctld` systemd override (`User=root`), and installs PMIx via `libpmix-dev` (also in both `01-base-system.sh` scripts)

## Head Node Scripts (`head-node/`)

Run on **pi-node0** in order:

| Script | Purpose |
|--------|---------|
| `01-base-system.sh` | System update, packages (incl. `libpmix-dev`), PCIe config |
| `02-network.sh` | Static IP (`192.168.129.36`), hostname, `/etc/hosts`, disable cloud-init |
| `03-users.sh` | Create munge (UID 64003), slurm (UID 64002), user (UID 2000) |
| `04-chrony.sh` | NTP server — serves `192.168.129.0/24`, syncs from Debian pool |
| `05-nfs-server.sh` | USB SSD mount (`nofail`), bind mounts + NFS exports |
| `06-munge.sh` | Generate munge.key, distribute to compute nodes, verify |
| `07-slurm-controller.sh` | slurm-no-mail, root override, live slurm.conf/cgroup.conf, start daemons |

## Compute Node Scripts (`compute-node/`)

Run on **pi-node1, pi-node2, pi-node3** in order (after head node is configured):

| Script | Purpose |
|--------|---------|
| `01-base-system.sh` | System update, slurmd + `libpmix-dev`, PCIe config |
| `02-network.sh` | Static IP (by hostname), `/etc/hosts`, disable cloud-init |
| `03-users.sh` | Create munge/slurm/user with identical UIDs |
| `04-chrony.sh` | NTP client — syncs from pi-node0 |
| `05-nfs-client.sh` | Mount `/shared` and `/home/user` from pi-node0 |
| `06-munge.sh` | Receive and verify munge.key, start munged |
| `07-slurm-node.sh` | Fetch slurm.conf from pi-node0, start slurmd |

## Operations Scripts (`ops/`)

Run on **pi-node0** as root:

| Script | Purpose |
|--------|---------|
| `cluster-startup.sh` | Start all services in correct dependency order |
| `cluster-shutdown.sh` | Drain jobs, unmount NFS on clients first, stop services, shutdown |
| `cluster-reboot.sh` | Rolling reboot (default) or full reboot (`--mode=full`) |

## Quick Start

```bash
# On pi-node0 (head node):
cd scripts/head-node/
for s in 01 02 03 04 05 06 07; do
    sudo bash ${s}-*.sh
done

# On each compute node (pi-node1, pi-node2, pi-node3):
cd scripts/compute-node/
for s in 01 02 03 04 05 06 07; do
    sudo bash ${s}-*.sh
done
```
