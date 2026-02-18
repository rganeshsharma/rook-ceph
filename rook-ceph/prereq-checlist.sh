# MUST HAVE:

# ✅ LVM2 installed on all nodes
# ✅ RBD kernel module loaded and persistent
# ✅ Raw block devices available (no filesystem, not mounted)
# ✅ Minimum 3 nodes with storage
# ✅ Time synchronization (chronyd/NTP)
# ✅ Kubernetes 1.24+
# ✅ Sufficient resources (16GB+ RAM per storage node)
# ✅ Network connectivity between nodes


## cat <<'EOF' > rook-ceph-preflight.sh

#!/bin/bash
echo "==================================="
echo "Rook-Ceph Pre-Flight Check for RKE2"
echo "==================================="
echo ""

FAIL=0

# 1. Check OS packages
echo "1. Checking required packages..."
for pkg in lvm2 gdisk parted; do
    if ! command -v $pkg &> /dev/null; then
        echo "   ❌ $pkg not installed"
        FAIL=1
    else
        echo "   ✅ $pkg installed"
    fi
done

# 2. Check kernel modules
echo ""
echo "2. Checking kernel modules..."
for mod in rbd nbd; do
    if lsmod | grep -q $mod; then
        echo "   ✅ $mod module loaded"
    else
        echo "   ❌ $mod module not loaded"
        FAIL=1
    fi
done

# 3. Check time sync
echo ""
echo "3. Checking time synchronization..."
if systemctl is-active --quiet chronyd || systemctl is-active --quiet systemd-timesyncd; then
    echo "   ✅ Time sync service running"
else
    echo "   ❌ No time sync service running"
    FAIL=1
fi

# 4. Check Kubernetes version
echo ""
echo "4. Checking Kubernetes version..."
K8S_VERSION=$(kubectl version --short 2>/dev/null | grep Server | awk '{print $3}')
echo "   Kubernetes version: $K8S_VERSION"
if [[ "$K8S_VERSION" < "v1.24" ]]; then
    echo "   ❌ Kubernetes version too old (minimum v1.24)"
    FAIL=1
else
    echo "   ✅ Kubernetes version supported"
fi

# 5. Check available disks
echo ""
echo "5. Checking available disks..."
AVAIL_DISKS=0
for disk in $(lsblk -d -n -o NAME | grep -v '^loop\|^sr'); do
    if [ ! -b /dev/$disk ]; then
        continue
    fi
    
    # Skip if has filesystem
    if sudo blkid /dev/$disk > /dev/null 2>&1; then
        continue
    fi
    
    # Skip if mounted
    if mount | grep -q /dev/$disk; then
        continue
    fi
    
    # Skip if in LVM
    if sudo pvs 2>/dev/null | grep -q $disk; then
        continue
    fi
    
    size=$(lsblk -b -d -n -o SIZE /dev/$disk 2>/dev/null)
    size_gb=$((size / 1024 / 1024 / 1024))
    
    if [ $size_gb -ge 50 ]; then
        echo "   ✅ /dev/$disk available (${size_gb}GB)"
        AVAIL_DISKS=$((AVAIL_DISKS + 1))
    fi
done

if [ $AVAIL_DISKS -lt 1 ]; then
    echo "   ❌ No suitable disks found"
    FAIL=1
fi

# 6. Check node resources
echo ""
echo "6. Checking node resources..."
NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
echo "   Nodes: $NODE_COUNT"

if [ $NODE_COUNT -lt 3 ]; then
    echo "   ⚠️  Less than 3 nodes (minimum recommended)"
fi

# 7. Check networking
echo ""
echo "7. Checking network connectivity..."
if nc -zv -w 2 $(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}') 6789 2>&1 | grep -q succeeded; then
    echo "   ✅ Port 6789 accessible"
else
    echo "   ⚠️  Port 6789 may be blocked"
fi

# Summary
echo ""
echo "==================================="
if [ $FAIL -eq 0 ]; then
    echo "✅ All critical checks passed!"
    echo "   Ready to deploy Rook-Ceph"
else
    echo "❌ Some checks failed"
    echo "   Fix issues before deploying"
    exit 1
fi
echo "==================================="
## EOF

## chmod +x rook-ceph-preflight.sh
## sudo ./rook-ceph-preflight.sh