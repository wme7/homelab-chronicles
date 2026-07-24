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
