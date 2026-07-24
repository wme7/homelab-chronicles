# On all nodes
sudo mkdir -p /var/spool/slurm/d /var/log/slurm
sudo chown slurm:slurm /var/spool/slurm/d /var/log/slurm

# On pi-node0 only:
sudo mkdir -p /var/spool/slurm/ctld
sudo chown slurm:slurm /var/spool/slurm/ctld
