# 1. Rook-Ceph Cluster minimum hardware requirements
## Minimum hardware requirements per Node

```text
CPU:     4 cores minimum (8+ recommended for production)
RAM:     16GB minimum (32GB+ recommended)
         - Base OS: 2-4GB
         - Kubernetes: 2-4GB
         - Per OSD: 4-8GB
         - MON: 2GB
         - MGR: 2GB
         
Storage: Raw block devices (unformatted)
         - Minimum 3 nodes with storage
         - Minimum 100GB per disk (preferably 500GB+)
         - SSD strongly recommended for OSDs
         - NVMe ideal for performance-critical workloads
         
Network: 1Gbps minimum (10Gbps recommended for production)
         - Separate cluster network ideal (optional)
```

## Example for 3 worker nodes
### Each node: 2 OSDs (disks) of 500GB each
```text
Total OSD count = 3 nodes × 2 disks = 6 OSDs
RAM per node = (6/3 × 6GB) + 2GB (MON) + 2GB (MGR) + 4GB (OS/K8s) = 20GB minimum
Usable storage = (6 × 500GB) / 3 replicas = 1TB usable


Our example:
Total OSD count = 3 nodes × 1 disks = 3 OSDs
RAM per node = (3 × 6GB) + 2GB (MON) + 2GB (MGR) + 4GB (OS/K8s) = 20GB minimum
Usable storage = (3 × 50GB) / 3 replicas = 50GB usable
```

# 2. Operating System Requirements :

```bash
## 1. Install LVM2 (REQUIRED)
### Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y lvm2

### RHEL/CentOS/Rocky
sudo yum install -y lvm2

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

# RHEL/CentOS
sudo yum install -y \
    gdisk \
    parted \
    util-linux-ng \
    cryptsetup
```

```bash
# 1. List all block devices
lsblk -f

# Example output:
# NAME   FSTYPE   LABEL  UUID                                 MOUNTPOINT
# sda
# ├─sda1 ext4            xxx-xxx-xxx                          /
# ├─sda2 swap            yyy-yyy-yyy                          [SWAP]
# sdb                                                         <- AVAILABLE for Ceph
# sdc    ext4            zzz-zzz-zzz                          /data  <- NOT available

# 2. Check disk details
sudo lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,MODEL,SERIAL

# 3. Verify disks are empty (no filesystem)
sudo blkid /dev/sdb  # Should return nothing

# 4. Check for partition tables
sudo sgdisk -p /dev/sdb  # Should show no partitions or error

# 5. Verify not in use by LVM
sudo pvs | grep sdb  # Should return nothing
sudo vgs | grep sdb
sudo lvs | grep sdb

# 6. Check if disk is mounted
mount | grep sdb  # Should return nothing

# 7. Check disk health (optional but recommended)
sudo smartctl -a /dev/sdb  # Requires smartmontools
```

```bash
# ⚠️ DANGER: This WIPES ALL DATA on the disk
# Only run on disks you want to dedicate to Ceph

# Method 1: Complete disk wipe (RECOMMENDED)
sudo wipefs -af /dev/sdb
sudo sgdisk --zap-all /dev/sdb
sudo dd if=/dev/zero of=/dev/sdb bs=1M count=100 oflag=direct,dsync

# Method 2: Quick wipe (faster but less thorough)
sudo wipefs -af /dev/sdb
sudo dd if=/dev/zero of=/dev/sdb bs=1M count=10

# Verify disk is clean
lsblk -f /dev/sdb
# Should show:
# NAME FSTYPE LABEL UUID MOUNTPOINT
# sdb

sudo blkid /dev/sdb  # Should return nothing

# Inform kernel of changes
sudo partprobe /dev/sdb
```

# Create a verification script
```sh
cat <<'EOF' > check-ceph-disks.sh
#!/bin/bash

echo "=== Checking Ceph Disk Prerequisites ==="
echo ""

for disk in sdb sdc; do
    echo "Checking /dev/$disk..."
    
    # Check if disk exists
    if [ ! -b /dev/$disk ]; then
        echo "  ❌ Disk does not exist"
        continue
    fi
    
    # Check if has filesystem
    if sudo blkid /dev/$disk > /dev/null 2>&1; then
        echo "  ❌ Has filesystem: $(sudo blkid /dev/$disk)"
        continue
    fi
    
    # Check if mounted
    if mount | grep -q /dev/$disk; then
        echo "  ❌ Is mounted: $(mount | grep /dev/$disk)"
        continue
    fi
    
    # Check if used by LVM
    if sudo pvs 2>/dev/null | grep -q $disk; then
        echo "  ❌ Used by LVM"
        continue
    fi
    
    # Check size
    size=$(lsblk -b -d -n -o SIZE /dev/$disk)
    size_gb=$((size / 1024 / 1024 / 1024))
    
    if [ $size_gb -lt 50 ]; then
        echo "  ⚠️  Disk too small: ${size_gb}GB (minimum 50GB recommended)"
    fi
    
    echo "  ✅ Available for Ceph (${size_gb}GB)"
done
EOF
```
```bash
chmod +x check-ceph-disks.sh
sudo ./check-ceph-disks.sh
```

# RKE2 Configurations Parameters:
```bash
# 1. Check RKE2 version (should be 1.24+)
kubectl version

# Minimum supported: v1.24+
# Recommended: v1.27+

# 2. Verify kubelet configuration
# Find kubelet path
ps aux | grep kubelet | grep root-dir

# Should show something like:
# --root-dir=/var/lib/kubelet

# 3. Check if CSI support is enabled
kubectl get csinode
# Should return list of nodes

kubectl get csidrivers
# May be empty initially (Rook will create them)

# 4. Verify feature gates (if customized)
kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}'


# Check RKE2 server config
cat /etc/rancher/rke2/config.yaml
```

## Verify the following :
```text
 Should NOT have conflicting settings
 Verify these are NOT set to restrictive values:
- pod-security-policy (deprecated in 1.25+)
- admission plugins that might block Rook
```

# 1. Verify nodes can communicate on required ports
```text
Ceph MON: 3300, 6789
Ceph MGR: 6800-7300, 8443 (dashboard), 9283 (metrics)
Ceph OSD: 6800-7300
Ceph MDS: 6800
```

# Test connectivity between nodes
```bash
# From node1 to node2
nc -zv <node2-ip> 6789
nc -zv <node2-ip> 3300

# 2. Check firewall rules (if enabled)
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
iperf3 -c <server-node-ip>
# Should show > 1 Gbps for production


# If firewall is enabled, allow these ports
# Ubuntu (ufw)
sudo ufw allow 3300/tcp
sudo ufw allow 6789/tcp
sudo ufw allow 6800:7300/tcp
sudo ufw allow 8443/tcp
sudo ufw allow 9283/tcp
sudo ufw reload
sudo ufw allow 


# Create rook-ceph namespace (or let Helm do it)
kubectl create namespace rook-ceph

# Label storage nodes (if using dedicated storage nodes)
kubectl label nodes rdagent1 storage=ceph
kubectl label nodes rdagent2 storage=ceph
kubectl label nodes rdagent3 storage=ceph

# Optional: Taint storage nodes to dedicate them (PRODUCTION)
kubectl taint nodes rdagent1 storage=ceph:NoSchedule
kubectl taint nodes rdagent2 storage=ceph:NoSchedule
kubectl taint nodes rdagent3 storage=ceph:NoSchedule

# 1. Check current limits
ulimit -a

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
```


# Ceph requires synchronized clocks across all nodes
```bash
# 1. Check if NTP/Chrony is running
systemctl status systemd-timesyncd  # Ubuntu

# 2. If not installed, install chrony
sudo apt-get install -y chrony  # Ubuntu

# 3. Enable and start
sudo systemctl start chronyd
sudo systemctl enable chronyd

# 4. Verify time sync
chronyc tracking
chronyc sources

# 5. Check time difference between nodes
# On each node
date +%s
```
# NOTE: Difference should be < 50ms (0.05 seconds)


# 9. Container Runtime Prerequisites

```bash
# 1. Verify container runtime (RKE2 uses containerd)
sudo crictl version

# 2. Check containerd configuration
sudo cat /var/lib/rancher/rke2/agent/etc/containerd/config.toml

# 3. Verify privileged containers are allowed (required for Ceph)
# Check if PSP or Pod Security Standards are blocking privileged pods
kubectl get psp  # Should be empty or allow privileged
kubectl get podsecuritypolicies

# 4. If using Pod Security Admission (K8s 1.25+)
kubectl label namespace rook-ceph pod-security.kubernetes.io/enforce=privileged
kubectl label namespace rook-ceph pod-security.kubernetes.io/audit=privileged
kubectl label namespace rook-ceph pod-security.kubernetes.io/warn=privileged
```

# 10. Helm Prerequisites

```bash
# 1. Install Helm 3 (if not already installed)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
helm version

# 2. Add Rook Helm repository
helm repo add rook-release https://charts.rook.io/release
helm repo update

# 3. Verify repository
helm search repo rook-ceph

# 4. To Download a new copy of values.yml 
helm show values rook-release/rook-ceph-cluster > ceph-cluster-values.yml

helm upgrade --install rook-ceph rook-release/rook-ceph 
  --namespace rook-ceph --set crds.enabled=true -f override-values.yml
```

# 11. Monitoring Prerequisites (Optional but Recommended)

```bash
# If you want monitoring integration
# 1. Check if Prometheus is installed
kubectl get pods -n monitoring | grep prometheus

# 2. Verify ServiceMonitor CRD exists
kubectl get crd servicemonitors.monitoring.coreos.com

# If Prometheus not installed, you can skip this
# Monitoring can be added later
```


