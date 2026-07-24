echo 'admin ALL=(ALL) NOPASSWD: ALL' \
  | sudo tee /etc/sudoers.d/cluster-admin
sudo chmod 0440 /etc/sudoers.d/cluster-admin
