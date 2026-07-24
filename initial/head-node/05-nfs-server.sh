sudo apt install nfs-kernel-server -y

sudo tee /etc/exports << 'EOF'
/shared  192.168.129.0/24(rw,sync,no_root_squash,no_subtree_check)
EOF

sudo exportfs -rav
sudo systemctl enable --now nfs-server
