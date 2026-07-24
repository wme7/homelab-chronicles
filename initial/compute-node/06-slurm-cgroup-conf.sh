sudo tee /etc/slurm/cgroup.conf << 'EOF'
CgroupPlugin=disabled
CgroupAutomount=yes
ConstrainCores=no
ConstrainRAMSpace=no
ConstrainDevices=no
EOF
