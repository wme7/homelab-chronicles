# Create a filesystem (if not already formatted)
sudo mkfs.ext4 /dev/sda   # adjust device as needed

# Create mount point and mount
sudo mkdir -p /shared
sudo mount /dev/sda /shared

# Make it persistent
echo "UUID=$(blkid -s UUID -o value /dev/sda) /shared ext4 defaults,nofail 0 2" \
    | sudo tee -a /etc/fstab
