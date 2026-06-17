# Task: Design and Document a Raspberry Pi 5 SLURM Cluster

You are a Linux systems engineer and HPC cluster administrator.

Your task is to design, document, and automate the deployment of a small SLURM cluster built from Raspberry Pi 5 boards.

The following hardware has been acquired to build the cluster:

**Hardware Inventory:**
- 4x Raspberry Pi 5 - 16GB,
- 4x M.2 NVME M-Key 2242 and PoE HAT for RPi5,
- 4x Transcend 256G NVMe PCIe Gen3 x4 M.2 2242 SSD,
- 1x NETGEAR (GS305EPP) 5 Port Gigabit RJ45 Ethernet PoE Switch (10/100/1000),
- 1x USB external 1TB SSD (for shared storage).

**Steps:**

- Investigate online for tutorials on installing SLURM on debian based systems.
- Investigate online for tutorials of similar projects and compile a deployment guide.
- Document the setup process and found caveats.

**Deliverables:**

- Produce a complete deployment guide in Markdown.
- Provide a set of bash scripts ready to be used to set up the cluster.
- Separate the scripts into two sets:
  - one for the head node and controller node 0, and
  - one for the compute nodes 1, 2 and 3.
- Provide instructions and scripts to shutdown the cluster.
- Provide instructions and scripts to restart the cluster.

**Main assumptions:**
- Use the lastest Pi OS Lite version: Trixie, from 21 Apr 2026.
- Prefer packages already available in Debian Apt repository.
- Use all 4-nodes for doing computation.
- For simplicity, I wish to create an `admin` (root) user a `user` (a non-root) user.
- The hostnames are will be set as:
  - `192.168.1.101` `pi-node0` (head node and controller)
  - `192.168.1.102` `pi-node1` (compute node)
  - `192.168.1.103` `pi-node2` (compute node)
  - `192.168.1.104` `pi-node3` (compute node)

**Instructions:**
- Install the OS on the NVME SSD of each node.
- Configure the network and hostname of each node.
- Create the `admin` and `user` users.
- Configure the time synchronization (chrony) on each node.
- Configure the passwordless SSH between nodes.
- Configure the shared storage (NFS + USB drive).
- Configure the MUNGE authentication.
- Configure the SLURM installation and configuration.