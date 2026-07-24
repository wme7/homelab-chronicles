# Create a no-op mail script
sudo tee /usr/local/bin/slurm-no-mail << 'EOF'
#!/bin/sh
exit 0
EOF
sudo chmod +x /usr/local/bin/slurm-no-mail
