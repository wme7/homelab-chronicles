# Install NFS system
sudo apt install nfs-common -y

# Create /shared folder
sudo mkdir -p /shared

# Add shared folder to /etc/fstab
echo "pi-node0:/shared  /shared  nfs  defaults,_netdev  0  0" \
    | sudo tee -a /etc/fstab

# Reload system daemon
systemctl daemon-reload # Root psw is requeted

# Mount shared for admin user
sudo mount -a
ls /shared   # should show home, scratch, software

# Mount shared also for users
sudo usermod -d /shared/home/user user
