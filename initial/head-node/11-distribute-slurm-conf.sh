# From pi-node0
for node in pi-node1 pi-node2 pi-node3; do
    scp /etc/slurm/slurm.conf admin@$node:/tmp/slurm.conf
    scp /etc/slurm/cgroup.conf admin@$node:/tmp/cgroup.conf

    ssh admin@$node '
        sudo install -o root -g root -m 644 /tmp/slurm.conf  /etc/slurm/slurm.conf &&
        sudo install -o root -g root -m 644 /tmp/cgroup.conf /etc/slurm/cgroup.conf &&
        rm -f /tmp/slurm.conf /tmp/cgroup.conf
    '
done

