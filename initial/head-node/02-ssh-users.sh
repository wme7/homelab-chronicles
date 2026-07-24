# For admin user
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
for node in pi-node1 pi-node2 pi-node3; do
    ssh-copy-id admin@$node
done

# For user user
sudo -u user bash -c '
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
'
for node in pi-node1 pi-node2 pi-node3; do
    sudo -u user ssh-copy-id user@$node
done

# Also copy pi-node0's own public key to itself
ssh-copy-id admin@pi-node0
sudo -u user ssh-copy-id user@pi-node0
