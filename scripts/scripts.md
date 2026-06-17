# Automation Scripts

See the [deployment guide](../documents/guide.md) for full documentation.

## Head Node Scripts (`head-node/`)

Run on **pi-node0** in order:

| Script | Purpose |
|--------|---------|
| `01-base-system.sh` | System update, package install, PCIe/cgroup config |
| `02-network.sh` | Static IP (192.168.1.101), hostname, /etc/hosts |
| `03-users.sh` | Create munge (UID 64003), slurm (UID 64002), user (UID 2000) |
| `04-chrony.sh` | NTP server — serves 192.168.1.0/24, syncs from Debian pool |
| `05-nfs-server.sh` | USB SSD mount, NFS exports for /shared and /home/user |
| `06-munge.sh` | Generate munge.key, distribute to compute nodes, verify |
| `07-slurm-controller.sh` | Write slurm.conf + cgroup.conf, start slurmctld + slurmd |

## Compute Node Scripts (`compute-node/`)

Run on **pi-node1, pi-node2, pi-node3** in order (after head node is configured):

| Script | Purpose |
|--------|---------|
| `01-base-system.sh` | System update, slurmd package, PCIe/cgroup config |
| `02-network.sh` | Static IP (auto-detected by hostname), /etc/hosts |
| `03-users.sh` | Create munge/slurm/user with identical UIDs |
| `04-chrony.sh` | NTP client — syncs from pi-node0 |
| `05-nfs-client.sh` | Mount /shared and /home/user from pi-node0 |
| `06-munge.sh` | Receive and verify munge.key, start munged |
| `07-slurm-node.sh` | Fetch slurm.conf from pi-node0, start slurmd |

## Operations Scripts (`ops/`)

Run on **pi-node0** as root:

| Script | Purpose |
|--------|---------|
| `cluster-startup.sh` | Start all services in correct dependency order |
| `cluster-shutdown.sh` | Drain jobs, stop services, shutdown all nodes |
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
