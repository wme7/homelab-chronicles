# Task: Design and Document a Raspberry Pi 5 SLURM Cluster

You are a Linux systems engineer and HPC cluster administrator.

Your task is to design, document, and automate the deployment of a small SLURM cluster built from Raspberry Pi 5 boards.

## Hardware Inventory

### Raspberry Pi Cluster Nodes

* 4 × Raspberry Pi 5 (16 GB RAM)
* 4 × Raspberry Pi 5 M.2 NVMe M-Key 2242 + PoE HAT
* 4 × Transcend 256 GB NVMe PCIe Gen3 x4 M.2 2242 SSD
* 1 × NETGEAR GS305EPP 5-port Gigabit PoE switch
* 1 × External USB SSD (1 TB) for shared storage

## Cluster Architecture

### Node Roles

| Hostname | IP Address    | Role                                    |
| -------- | ------------- | --------------------------------------- |
| pi-node0 | 192.168.1.101 | Head node, SLURM controller, NFS server |
| pi-node1 | 192.168.1.102 | Compute node                            |
| pi-node2 | 192.168.1.103 | Compute node                            |
| pi-node3 | 192.168.1.104 | Compute node                            |

### Requirements

All four Raspberry Pi systems must be available for computation, including `pi-node0` unless there is a compelling technical reason to reserve it exclusively as the controller.

## Operating System

Use:

* Raspberry Pi OS Lite (64-bit)
* Debian Trixie
* Release date: 21 April 2026 or newer

Prefer packages available directly from Debian/Raspberry Pi APT repositories whenever possible.

Avoid compiling software from source unless absolutely necessary.

## User Accounts

Create:

### Administrative Account

```text
admin
```

* sudo privileges
* SSH access enabled

### Standard User

```text
user
```

* intended for SLURM job execution
* no sudo privileges

## Research Requirements

Before producing the solution:

1. Research current Raspberry Pi 5 cluster projects.
2. Research current SLURM installation procedures for Debian/Trixie.
3. Research any Raspberry Pi 5 specific caveats.
4. Research MUNGE and NFS configuration best practices.
5. Identify known issues, limitations, and workarounds.

For every significant recommendation:

* explain why it was chosen,
* explain alternatives,
* document any trade-offs.

## Deliverables

Produce a complete deployment guide in Markdown.

The guide must be written as if it will be followed from a clean installation.

### Deliverable 1: Architecture Overview

Provide:

* cluster topology
* network design
* storage design
* authentication design
* SLURM architecture

### Deliverable 2: Installation Guide

Document:

1. NVMe boot configuration
2. Raspberry Pi OS installation
3. Static network configuration
4. Hostname configuration
5. User creation
6. SSH configuration
7. Chrony configuration
8. NFS shared storage configuration
9. MUNGE configuration
10. SLURM installation
11. SLURM configuration
12. Cluster validation

Include verification commands after every major step.

### Deliverable 3: Caveats and Troubleshooting

Document:

* Raspberry Pi 5 hardware caveats
* NVMe boot caveats
* PoE considerations
* Time synchronization issues
* MUNGE issues
* NFS issues
* SLURM issues

Provide troubleshooting procedures and diagnostic commands.

### Deliverable 4: Automation Scripts

Generate production-ready Bash scripts.

Requirements:

* Scripts must be idempotent.
* Scripts must use `set -euo pipefail`.
* Scripts must include comments.
* Scripts must validate prerequisites.
* Scripts must log actions.
* Scripts must be safe to rerun.

Organize scripts into:

#### Head Node Scripts

Examples:

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

Examples:

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

Provide scripts and procedures for:

#### Startup

* start all services
* validate cluster health

#### Shutdown

* drain SLURM jobs
* shutdown compute nodes
* shutdown controller node

#### Reboot

* rolling reboot
* full cluster reboot

### Deliverable 6: Validation and Testing

Provide:

* commands to verify MUNGE
* commands to verify NFS
* commands to verify SLURM
* sample SLURM batch jobs
* CPU stress test example
* distributed MPI test example (if applicable)

### Deliverable 7: Final Configuration Files

Provide complete contents of:

```text
/etc/hosts
/etc/exports
/etc/chrony/chrony.conf
/etc/munge/munge.key deployment process
/etc/slurm/slurm.conf
/etc/slurm/cgroup.conf
```

Do not omit sections with placeholders.

Generate complete working examples.

## Output Format

Structure the final response as:

1. Research Findings
2. Architecture Decisions
3. Deployment Guide
4. Configuration Files
5. Automation Scripts
6. Operations Guide
7. Validation Procedures
8. Troubleshooting Guide
9. Future Improvements

Assume the reader has basic Linux knowledge but no prior SLURM administration experience.

Where information is uncertain or version-dependent, explicitly state assumptions and provide verification steps.
