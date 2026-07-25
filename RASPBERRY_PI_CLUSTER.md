# RASPBERRY PI CLUSTER
by Manuel A. Diaz on June 15, 2026

# Introduction

As a CFD engineer & Researcher, I often need to prototype new ideas and test them quickly. 
But in post-pandemic times, faster computers have become extremely expensive, and more often than not, waiting long queues for resources on supercomputers has become the norm. 

The idea of having a cluster of Raspberry Pi computers at home is not new. But having a micro cluster for prototyping at home has become a necessity for me. Specially when all I need is a few cores (say 8-16 with 16-64GB of RAM) and a standard SLURM infrastructure to test my ideas before launching them on a supercomputer. 

In this sense, this repository is aimed to CFD engineers and researchers that wish to have their own prototyping enviroment, that want to learn how SLURM cluster work on a deeper level, and wish to help to de-clutter the queue of supercomputers on universities and national laboratories.

This journey will be documented in this repository, and will be updated as I progress.

# Hardware

The hardware used for this project is the following:

- 4x Raspberry Pi 5 - 16GB,
- 4x M.2 NVME M-Key 2242 and PoE HAT for RPi5,
- 4x Transcend 256G NVMe PCIe Gen3 x4 M.2 2242 SSD,
- 1x NETGEAR (GS305EPP) 5 Port Gigabit RJ45 Ethernet PoE Switch (10/100/1000),
- 1x USB external 1TB SSD (for shared storage).

> __Note__: I bought most of this hardware in 2025 from Amazon. 
Currently the prices due to the inflation and the memory shortage are making this project extremely expensive. 
However, any avid tech-savvy is aware that nowdays there are better alternatives to Raspberry Pi 5 boards at much more affordable prices.

# Software Stack

The software stack I wish to have in my cluster is the following:

- Pi OS Lite - Debian Trixie, from 21 Apr 2026.
- SLURM - 24.11.5.
- Python - 3.14.
- Julia - 1.11.1.
- C/C++ - 17.
- OpenMPI - 5.0.1.
- CMake - 3.28.4.

> __Note__: I have a strong preference for C/C++, Python and Julia. Thus I'm here I'm aiming to a fully compute-oriented environment.

# Methodology

The objective here is not creating an updated guide to build a SLURM cluster using Raspberry Pi's in 2026. but rather to have a process that can deal with this requirements and be updated as the software stack evolves.

In other words, we would develop an educated `prompt` that can be used by commercial AI (Claude's Sonnet 4.6) to assist on compiling a guide (or develop fully automated scripts) to build the mini-cluster I wish to have.

Steps:
- An initial prompt was manually written [here](./initial/prompt_initial.md). 
- This prompt was used to generate an initial [guide](./initial/guide_initial.md) (in markdown format) and a set of basic scripts to build the cluster.
- The guide was reviewed and the scripts were tested manually. Several iterations/, fixes and changes were needed to get the cluster fully operational.
- The initial prompt was updated with new assumptions and requirements [here](./documents/prompt_final.md).
- The guide is now updated with the final version [here](./documents/guide.md) and its companion scripts [here](./scripts/scripts.md).

# Results

The final results of this project are the following:

- A guide (in markdown format) to build the cluster.
- A set of fully automated scripts to build the cluster.
- A cluster that is fully operational.

> __Note__: The guide and scripts are available [here](./documents/guide.md) and [here](./scripts/scripts.md).

> __Note__: The cluster is fully operational with caveats as it passes all the initial verifications and stress tests, but clearely some fine tunning of the SLURM configuration is needed as Sonnet 4.6 (medium) is making several assumptions on the Pi's hardware and software stack.

# Final Thoughts

This project has been a great learning experience. It has been a challenge to get the cluster fully operational, but also shows how important the quality of the prompt is to get the desired results.
