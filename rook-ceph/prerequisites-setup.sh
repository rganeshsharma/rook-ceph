#!/bin/bash

## 1. Install LVM2 (REQUIRED)
### Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y lvm2

### Verify
sudo vgs
sudo pvs
sudo lvs

## 2. Load RBD Kernel Module (REQUIRED)
sudo modprobe rbd

# Make it persistent across reboots
echo 'rbd' | sudo tee -a /etc/modules-load.d/rbd.conf

# Verify module is loaded
lsmod | grep rbd

# 3. Verify other required kernel modules
sudo modprobe nbd  # For RBD mapping
sudo modprobe ceph  # Ceph kernel module

# Make persistent
cat <<EOF | sudo tee -a /etc/modules-load.d/ceph.conf
rbd
nbd
ceph
EOF

# 4. Install additional utilities
# Ubuntu/Debian
sudo apt-get install -y \
    gdisk \
    parted \
    util-linux \
    cryptsetup  # If using encryption


# Inform kernel of changes
sudo partprobe /dev/sdb

# Test connectivity between nodes
# From node1 to node2
nc -zv <node2-ip> 6789
nc -zv <node2-ip> 3300

# 2. Check firewall rules (if enabled)
sudo firewall-cmd --list-all  # RHEL/CentOS
sudo ufw status                # Ubuntu

# 3. Verify DNS resolution
nslookup worker-node-1
nslookup worker-node-2
nslookup worker-node-3

# 4. Check network bandwidth
# Install iperf3
sudo apt-get install -y iperf3  # Ubuntu

# On server node
iperf3 -s

# On client node
iperf3 -c 172.24.23.29
iperf3 -c 172.24.23.27
iperf3 -c 172.24.23.28

# Should show > 1 Gbps for production

# If firewall is enabled, allow these ports

# RHEL/CentOS/Rocky (firewalld)
# Ubuntu (ufw)
sudo ufw allow 3300/tcp
sudo ufw allow 6789/tcp
sudo ufw allow 6800:7300/tcp
sudo ufw allow 8443/tcp
sudo ufw allow 9283/tcp
sudo ufw allow from 172.28.13.139 to any port 22 proto tcp
sudo ufw allow from 172.28.13.175 to any port 22 proto tcp
sudo ufw allow from 172.28.13.146 to any port 6443 proto tcp
sudo ufw allow from 172.28.13.147 to any port 6443 proto tcp
sudo ufw allow from 172.28.13.148 to any port 6443 proto tcp
sudo ufw allow from 172.28.13.149 to any port 6443 proto tcp
sudo ufw allow from 172.28.13.150 to any port 6443 proto tcp
sudo ufw allow from 172.28.13.151 to any port 6443 proto tcp
sudo ufw allow from 172.28.13.152 to any port 6443 proto tcp
sudo ufw allow from 172.24.23.0/24 to any port 6443 proto tcp
sudo ufw allow from 172.24.23.0/24 to any port 9345 proto tcp
sudo ufw allow from 172.24.23.0/24 to any port 10250 proto tcp
sudo ufw allow from 172.24.23.0/24 to any port 2379 proto tcp
sudo ufw allow from 172.24.23.0/24 to any port 2380 proto tcp
sudo ufw allow from 172.24.23.0/24 to any port 2381 proto tcp
sudo ufw allow from 172.24.23.0/24 to any port 30000:32767 proto tcp
sudo ufw allow from 172.24.23.0/24 to any port 8472 proto udp
sudo ufw allow from 172.24.23.0/24 to any port 51820 proto udp
sudo ufw allow from 172.24.23.0/24 to any port 51821 proto udp
sudo ufw allow from 172.24.23.0/24 to any port 9099 proto tcp
sudo ufw allow 9100
sudo ufw allow 6789
sudo ufw allow 3300/tcp
sudo ufw allow 6800:7300/tcp
sudo ufw allow 8443/tcp
sudo ufw allow 9283/tcp


# 2. Increase limits for Ceph processes
cat <<EOF | sudo tee /etc/security/limits.d/90-ceph.conf
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
EOF

# 3. Kernel parameters for Ceph
cat <<EOF | sudo tee /etc/sysctl.d/90-ceph.conf
# Increase max map count (for Ceph/OSD)
vm.max_map_count = 262144
# Network tuning
net.core.somaxconn = 1024
net.core.netdev_max_backlog = 5000
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_wmem = 4096 87380 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_max_syn_backlog = 8096
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
# Memory settings
vm.swappiness = 10
EOF

# Apply settings
sudo sysctl -p /etc/sysctl.d/90-ceph.conf

# 4. Disable swap (if not already disabled)
# Check current swap
sudo swapon --show

# Disable temporarily
sudo swapoff -a

# Disable permanently
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Ceph requires synchronized clocks across all nodes
# 1. Check if NTP/Chrony is running
systemctl status systemd-timesyncd  # Ubuntu

# 2. If not installed, install chrony
sudo apt-get install -y chrony  # Ubuntu

# 3. Enable and start
sudo systemctl enable chronyd
sudo systemctl start chronyd

# 4. Verify time sync
chronyc tracking
chronyc sources

# 5. Check time difference between nodes
# On each node
date +%s