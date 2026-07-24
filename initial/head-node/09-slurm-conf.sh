sudo tee /etc/slurm/slurm.conf << 'EOF'
# Cluster identity
ClusterName=picluster
SlurmctldHost=pi-node0

# Authentication
AuthType=auth/munge
CryptoType=crypto/munge

# Scheduling
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory

# Process tracking
ProctrackType=proctrack/linuxproc
TaskPlugin=task/affinity

# MPI default
MpiDefault=pmix

# Mail notifications
MailProg=/usr/local/bin/slurm-no-mail

# Logging
SlurmctldDebug=info
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdDebug=info
SlurmdLogFile=/var/log/slurm/slurmd.log

# Timeouts
SlurmctldTimeout=300
SlurmdTimeout=300
InactiveLimit=0
MinJobAge=300
KillWait=30
Waittime=0

# State persistence
StateSaveLocation=/var/spool/slurm/ctld
SlurmdSpoolDir=/var/spool/slurm/d

# PID files
SlurmctldPidFile=/var/run/slurmctld.pid
SlurmdPidFile=/var/run/slurmd.pid

# Ports
SlurmctldPort=6817
SlurmdPort=6818

# Return down nodes to service automatically
ReturnToService=2

# Node definitions (adjust RealMemory to actual available MB)
NodeName=pi-node0 NodeAddr=192.168.129.36 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN
NodeName=pi-node1 NodeAddr=192.168.129.37 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN
NodeName=pi-node2 NodeAddr=192.168.129.38 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN
NodeName=pi-node3 NodeAddr=192.168.129.39 CPUs=4 Sockets=1 CoresPerSocket=4 ThreadsPerCore=1 RealMemory=15000 State=UNKNOWN

# Partition (all 4 nodes available)
PartitionName=compute Nodes=pi-node[0-3] Default=YES MaxTime=INFINITE State=UP
EOF
