# NOTE : Kindly follow README.md inside rook-ceph and rook-ceph-cluster directory for Implementation 

# Rook-Ceph Deployment Guide for RKE2

Comprehensive guide for deploying Rook-Ceph distributed storage on RKE2 Kubernetes clusters in production environments.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Pre-Installation Setup](#pre-installation-setup)
- [Installation](#installation)
- [Post-Installation Configuration](#post-installation-configuration)
- [Verification](#verification)
- [Storage Class Configuration](#storage-class-configuration)
- [Dashboard Access](#dashboard-access)
- [Troubleshooting](#troubleshooting)
- [Maintenance](#maintenance)

---

## Overview

This repository contains configuration and deployment instructions for Rook-Ceph, a cloud-native storage orchestrator for Kubernetes that provides:

- **Block Storage (RBD)**: Persistent volumes for applications
- **File Storage (CephFS)**: Shared filesystem with ReadWriteMany support
- **Object Storage (RGW)**: S3-compatible object storage
- **Distributed Architecture**: High availability and fault tolerance
- **Self-healing**: Automatic recovery from failures

**Version Information:**
- Rook Operator: v1.19.0
- Ceph: v19.2.3 (Squid)
- Target Platform: RKE2 Kubernetes 1.27+

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    RKE2 Kubernetes Cluster                   │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ Worker Node 1│  │ Worker Node 2│  │ Worker Node 3│      │
│  │              │  │              │  │              │      │
│  │ MON-A  OSD-0 │  │ MON-B  OSD-1 │  │ MON-C  OSD-2 │      │
│  │ MGR-A        │  │ MGR-B        │  │              │      │
│  │              │  │              │  │              │      │
│  │ /dev/sdb     │  │ /dev/sdb     │  │ /dev/sdb     │      │
│  │ (Storage)    │  │ (Storage)    │  │ (Storage)    │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│                                                               │
│  ┌─────────────────────────────────────────────────────┐    │
│  │         Rook Operator (Orchestration)                │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                               │
│  ┌─────────────────────────────────────────────────────┐    │
│  │         CSI Drivers (RBD, CephFS)                    │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                               │
└─────────────────────────────────────────────────────────────┘

Components:
- MON (Monitor): Cluster state and quorum (3 replicas)
- MGR (Manager): Cluster operations, dashboard, metrics (2 replicas)
- OSD (Object Storage Daemon): Data storage (1 per disk)
- MDS (Metadata Server): CephFS metadata (optional)
- RGW (RADOS Gateway): Object storage API (optional)
```

---

## Prerequisites

### Hardware Requirements

**Per Storage Node:**
- **CPU**: 4 cores minimum (8+ recommended)
- **RAM**: 16GB minimum (32GB+ recommended)
  - Base OS + Kubernetes: 4-6GB
  - Per OSD: 4-8GB
  - MON: 2GB
  - MGR: 2GB
- **Storage**: Raw block devices (unformatted)
  - Minimum 3 nodes with storage
  - Minimum 100GB per disk (500GB+ recommended)
  - SSD strongly recommended for production
  - NVMe ideal for high-performance workloads
- **Network**: 1Gbps minimum (10Gbps recommended for production)

### Software Requirements

**All Storage Nodes:**
- RKE2 v1.27+ or compatible Kubernetes
- Linux kernel 5.11+ (for modern Ceph features)
- LVM2 installed
- `rbd` kernel module loaded

**Networking:**
- Calico, Cilium, or compatible CNI
- DNS resolution working
- Time synchronization (chrony/NTP)

### Cluster Requirements

- **Minimum Nodes**: 3 worker nodes with storage
- **RBAC**: Enabled
- **CSI Support**: CSINodeInfo and CSIDriverRegistry feature gates enabled
- **Storage Classes**: Existing or will be created by Rook

---

## Pre-Installation Setup

### 1. Prepare Storage Nodes

Run on **each worker node** that will provide storage:

```bash
# Install LVM2
# Ubuntu/Debian
sudo apt-get update && sudo apt-get install -y lvm2

# RHEL/CentOS/Rocky
sudo yum install -y lvm2

# Load RBD kernel module
sudo modprobe rbd
echo 'rbd' | sudo tee -a /etc/modules-load.d/rbd.conf

# Load additional required modules
sudo modprobe nbd
echo 'nbd' | sudo tee -a /etc/modules-load.d/ceph.conf

# Verify modules loaded
lsmod | grep rbd
lsmod | grep nbd
```

### 2. Identify and Prepare Disks

**Find Persistent Disk Identifiers:**

```bash
# Run on each storage node
ls -la /dev/disk/by-id/ | grep -v part | grep -v wwn

# Example output:
# ata-Samsung_SSD_870_EVO_1TB_S6PWNF0T123456A -> ../../sdb
# ata-WDC_WD10EZEX-08WN4A0_WD-WCC6Y7ABCD12 -> ../../sdc
```

⚠️ **CRITICAL**: Never use `/dev/sdb`, `/dev/sdc` names - they change on reboot!  
✅ **Always use** `/dev/disk/by-id/*` paths for stable identification.

**Prepare Raw Disks:**

⚠️ **WARNING**: This wipes all data!

```bash
# Only run on disks you want to dedicate to Ceph
sudo wipefs -af /dev/sdb
sudo sgdisk --zap-all /dev/sdb
sudo dd if=/dev/zero of=/dev/sdb bs=1M count=100 oflag=direct,dsync

# Verify disk is clean
lsblk -f /dev/sdb
# Should show no FSTYPE

sudo blkid /dev/sdb
# Should return nothing
```

### 3. System Configuration

```bash
# Increase system limits
sudo tee /etc/security/limits.d/90-ceph.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
EOF

# Kernel parameters
sudo tee /etc/sysctl.d/90-ceph.conf <<EOF
vm.max_map_count = 262144
vm.swappiness = 10
EOF

sudo sysctl -p /etc/sysctl.d/90-ceph.conf

# Disable swap (if not already disabled)
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
```

### 4. Time Synchronization

```bash
# Install and configure chrony
# Ubuntu/Debian
sudo apt-get install -y chrony

# RHEL/CentOS
sudo yum install -y chrony

# Enable and start
sudo systemctl enable chronyd
sudo systemctl start chronyd

# Verify sync
chronyc tracking
chronyc sources
```

### 5. Label Storage Nodes (Optional but Recommended)

```bash
# Label nodes for dedicated storage
kubectl label nodes worker-node-1 storage=ceph
kubectl label nodes worker-node-2 storage=ceph
kubectl label nodes worker-node-3 storage=ceph

# Optional: Taint to dedicate nodes to storage
kubectl taint nodes worker-node-1 storage=ceph:NoSchedule
kubectl taint nodes worker-node-2 storage=ceph:NoSchedule
kubectl taint nodes worker-node-3 storage=ceph:NoSchedule
```

### 6. Pre-Flight Validation

```bash
# Create validation script
cat > preflight-check.sh <<'EOF'
#!/bin/bash
echo "=== Rook-Ceph Pre-Flight Validation ==="
FAIL=0

# Check LVM2
if ! command -v lvm &> /dev/null; then
    echo "❌ LVM2 not installed"
    FAIL=1
else
    echo "✅ LVM2 installed"
fi

# Check RBD module
if lsmod | grep -q rbd; then
    echo "✅ RBD module loaded"
else
    echo "❌ RBD module not loaded"
    FAIL=1
fi

# Check kernel version
KERNEL_VERSION=$(uname -r | cut -d. -f1,2)
if [ "$(echo "$KERNEL_VERSION >= 5.11" | bc)" -eq 1 ]; then
    echo "✅ Kernel version: $(uname -r)"
else
    echo "⚠️  Kernel version: $(uname -r) (5.11+ recommended)"
fi

# Check available disks
DISK_COUNT=0
for disk in $(lsblk -d -n -o NAME | grep -v '^loop\|^sr\|^sda'); do
    if [ -b /dev/$disk ] && ! blkid /dev/$disk > /dev/null 2>&1; then
        size=$(lsblk -b -d -n -o SIZE /dev/$disk)
        size_gb=$((size / 1024 / 1024 / 1024))
        if [ $size_gb -ge 50 ]; then
            echo "✅ Disk /dev/$disk available (${size_gb}GB)"
            DISK_COUNT=$((DISK_COUNT + 1))
        fi
    fi
done

if [ $DISK_COUNT -eq 0 ]; then
    echo "❌ No suitable disks found"
    FAIL=1
fi

# Check time sync
if systemctl is-active --quiet chronyd || systemctl is-active --quiet systemd-timesyncd; then
    echo "✅ Time synchronization active"
else
    echo "❌ Time synchronization not running"
    FAIL=1
fi

# Check Kubernetes
if kubectl version --short &> /dev/null; then
    echo "✅ Kubernetes accessible"
else
    echo "❌ Cannot access Kubernetes"
    FAIL=1
fi

echo ""
if [ $FAIL -eq 0 ]; then
    echo "✅ All checks passed - Ready for Rook-Ceph deployment"
    exit 0
else
    echo "❌ Some checks failed - Fix issues before deploying"
    exit 1
fi
EOF

chmod +x preflight-check.sh
./preflight-check.sh
```

---

## Installation

### Step 1: Add Rook Helm Repository

```bash
# Add Rook Helm repository
helm repo add rook-release https://charts.rook.io/release
helm repo update

# Verify repository
helm search repo rook-ceph --versions
```

### Step 2: Create Namespace

```bash
# Create rook-ceph namespace
kubectl create namespace rook-ceph

# Optional: Label for monitoring
kubectl label namespace rook-ceph name=rook-ceph
```

### Step 3: Deploy Rook Operator

**Create Operator Values File:**

```bash
cat > rook-ceph-operator-values.yaml <<'EOF'
# Rook-Ceph Operator Configuration
image:
  repository: docker.io/rook/ceph
  tag: v1.19.0
  pullPolicy: IfNotPresent

# CRD Management
crds:
  enabled: true

# Operator Resources
resources:
  limits:
    memory: 2Gi
  requests:
    cpu: 500m
    memory: 512Mi

# Logging
logLevel: INFO

# RBAC
rbacEnable: true

# Security Context
containerSecurityContext:
  runAsNonRoot: true
  runAsUser: 2016
  runAsGroup: 2016
  capabilities:
    drop: ["ALL"]

# Never allow loop devices in production
allowLoopDevices: false

# CSI Configuration
csi:
  # Use CSI operator for modern deployment
  rookUseCsiOperator: true
  
  # Enable required drivers
  enableRbdDriver: true
  enableCephfsDriver: true
  disableCsiDriver: "false"
  
  # Network configuration
  enableCSIHostNetwork: true
  
  # Snapshot support
  enableRBDSnapshotter: true
  enableCephfsSnapshotter: true
  enableNFSSnapshotter: true
  
  # Encryption (disable if no KMS configured)
  enableCSIEncryption: false
  
  # Priority classes for stability
  pluginPriorityClassName: system-node-critical
  provisionerPriorityClassName: system-cluster-critical
  
  # Provisioner HA
  provisionerReplicas: 2
  
  # RKE2 specific configuration
  kubeletDirPath: /var/lib/kubelet
  
  # Timeouts
  grpcTimeoutInSeconds: 150

# Device Discovery
enableDiscoveryDaemon: true
discoveryDaemonInterval: 60m

# Prevent automatic device consumption
disableDeviceHotplug: false

# Monitoring (enable if Prometheus installed)
monitoring:
  enabled: true
EOF
```

**Deploy Operator:**

```bash
# Install Rook operator
helm install rook-ceph rook-release/rook-ceph \
  -f rook-ceph-operator-values.yaml \
  -n rook-ceph \
  --create-namespace \
  --timeout 10m

# Verify operator deployment
kubectl -n rook-ceph get pods -l app=rook-ceph-operator

# Should show:
# NAME                                 READY   STATUS    RESTARTS   AGE
# rook-ceph-operator-xxxxxxxxxx-xxxxx  1/1     Running   0          2m
```

### Step 4: Create Required ConfigMaps

```bash
# Create CSI KMS ConfigMap (required even without encryption)
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: rook-ceph-csi-kms-config
  namespace: rook-ceph
data:
  config.json: |-
    {}
EOF

# Verify
kubectl -n rook-ceph get configmap rook-ceph-csi-kms-config
```

### Step 5: Deploy Ceph Cluster

**Create Cluster Values File:**

```bash
cat > rook-ceph-cluster-values.yaml <<'EOF'
# Rook-Ceph Cluster Configuration
operatorNamespace: rook-ceph

# Toolbox for debugging
toolbox:
  enabled: true
  resources:
    limits:
      memory: "1Gi"
    requests:
      cpu: "100m"
      memory: "128Mi"

# Monitoring integration
monitoring:
  enabled: true
  metricsDisabled: false
  createPrometheusRules: true

# Ceph version
cephImage:
  repository: quay.io/ceph/ceph
  tag: v19.2.3
  allowUnsupported: false
  imagePullPolicy: IfNotPresent

# Cluster specification
cephClusterSpec:
  # Data directory
  dataDirHostPath: /var/lib/rook
  
  # Upgrade controls
  skipUpgradeChecks: false
  continueUpgradeAfterChecksEvenIfNotHealthy: false
  upgradeOSDRequiresHealthyPGs: true
  
  # Monitor configuration (cluster brain)
  mon:
    count: 3  # Always odd number
    allowMultiplePerNode: false
  
  # Manager configuration
  mgr:
    count: 2  # Active-standby
    allowMultiplePerNode: false
    modules:
      - name: pg_autoscaler
        enabled: true
  
  # Dashboard
  dashboard:
    enabled: true
    ssl: false  # Disable for easier ingress integration
    port: 7000
  
  # Network configuration
  network:
    connections:
      encryption:
        enabled: false  # Enable if compliance requires
      compression:
        enabled: false
      requireMsgr2: false  # Set true if kernel >= 5.11
  
  # Crash and log collection
  crashCollector:
    disable: false
  
  logCollector:
    enabled: true
    periodicity: daily
    maxLogSize: 500M
  
  # Cleanup policy (NEVER set confirmation unless deleting cluster)
  cleanupPolicy:
    confirmation: ""
    sanitizeDisks:
      method: quick
      dataSource: zero
      iteration: 1
    allowUninstallWithVolumes: false
  
  # Resource allocation
  resources:
    mon:
      limits:
        memory: "2Gi"
      requests:
        cpu: "1000m"
        memory: "1Gi"
    mgr:
      limits:
        memory: "2Gi"
      requests:
        cpu: "500m"
        memory: "1Gi"
    osd:
      limits:
        memory: "8Gi"
      requests:
        cpu: "2000m"
        memory: "6Gi"
    prepareosd:
      # No limits - one-time job needs burst
      requests:
        cpu: "500m"
        memory: "50Mi"
    mgr-sidecar:
      limits:
        memory: "100Mi"
      requests:
        cpu: "100m"
        memory: "40Mi"
    crashcollector:
      limits:
        memory: "60Mi"
      requests:
        cpu: "100m"
        memory: "60Mi"
    logcollector:
      limits:
        memory: "1Gi"
      requests:
        cpu: "100m"
        memory: "100Mi"
    cleanup:
      limits:
        memory: "1Gi"
      requests:
        cpu: "500m"
        memory: "100Mi"
  
  # Priority classes for pod eviction protection
  priorityClassNames:
    mon: system-node-critical
    osd: system-node-critical
    mgr: system-cluster-critical
  
  # Storage configuration
  # ⚠️ IMPORTANT: Use /dev/disk/by-id/* paths, NOT /dev/sdX
  storage:
    useAllNodes: false
    useAllDevices: false
    nodes:
      # Replace with your actual node names and disk IDs
      - name: "worker-node-1"
        devices:
          - name: "/dev/disk/by-id/ata-Samsung_SSD_870_EVO_1TB_S6PWNF0T123456A"
          # Add more disks as needed
      - name: "worker-node-2"
        devices:
          - name: "/dev/disk/by-id/ata-Samsung_SSD_870_EVO_1TB_S6PWNF0T234567B"
      - name: "worker-node-3"
        devices:
          - name: "/dev/disk/by-id/ata-Samsung_SSD_870_EVO_1TB_S6PWNF0T345678C"
    config:
      osdsPerDevice: "1"
  
  # Disruption management
  disruptionManagement:
    managePodBudgets: true
    osdMaintenanceTimeout: 30
  
  # Health checks
  healthCheck:
    daemonHealth:
      mon:
        disabled: false
        interval: 45s
      osd:
        disabled: false
        interval: 60s
      status:
        disabled: false
        interval: 60s
    livenessProbe:
      mon:
        disabled: false
      mgr:
        disabled: false
      osd:
        disabled: false

# Block storage pool and storage class
cephBlockPools:
  - name: replicapool
    spec:
      failureDomain: host
      replicated:
        size: 3
        requireSafeReplicaSize: true
      parameters:
        compression_mode: aggressive
        compression_algorithm: snappy
    storageClass:
      enabled: true
      name: rook-ceph-block
      isDefault: false
      reclaimPolicy: Delete
      allowVolumeExpansion: true
      volumeBindingMode: "WaitForFirstConsumer"
      parameters:
        imageFormat: "2"
        imageFeatures: layering
        csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
        csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
        csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
        csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
        csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
        csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
        csi.storage.k8s.io/fstype: ext4

# Disable CephFS if not needed
cephFileSystems: []

# Disable Object Storage if not needed
cephObjectStores: []

# Enable volume snapshots
cephBlockPoolsVolumeSnapshotClass:
  enabled: true
  name: rook-ceph-block
  isDefault: false
  deletionPolicy: Delete
EOF
```

**Important**: Update the `storage.nodes` section with your actual:
- Node hostnames (must match `kubernetes.io/hostname` label)
- Disk IDs from `/dev/disk/by-id/`

**Deploy Cluster:**

```bash
# Install Ceph cluster
helm install rook-ceph-cluster rook-release/rook-ceph-cluster \
  -f rook-ceph-cluster-values.yaml \
  -n rook-ceph \
  --timeout 15m

# Monitor deployment (takes 5-10 minutes)
watch kubectl -n rook-ceph get pods
```

**Expected Pods After Deployment:**

```
NAME                                                    READY   STATUS
rook-ceph-operator-xxxxxxxxxx-xxxxx                     1/1     Running
rook-ceph-mon-a-xxxxxxxxxx-xxxxx                        2/2     Running
rook-ceph-mon-b-xxxxxxxxxx-xxxxx                        2/2     Running
rook-ceph-mon-c-xxxxxxxxxx-xxxxx                        2/2     Running
rook-ceph-mgr-a-xxxxxxxxxx-xxxxx                        3/3     Running
rook-ceph-mgr-b-xxxxxxxxxx-xxxxx                        3/3     Running
rook-ceph-osd-0-xxxxxxxxxx-xxxxx                        2/2     Running
rook-ceph-osd-1-xxxxxxxxxx-xxxxx                        2/2     Running
rook-ceph-osd-2-xxxxxxxxxx-xxxxx                        2/2     Running
rook-ceph-osd-prepare-worker-node-1-xxxxx               0/1     Completed
rook-ceph-osd-prepare-worker-node-2-xxxxx               0/1     Completed
rook-ceph-osd-prepare-worker-node-3-xxxxx               0/1     Completed
rook-ceph-tools-xxxxxxxxxx-xxxxx                        1/1     Running
csi-cephfsplugin-provisioner-xxxxxxxxxx-xxxxx           6/6     Running
csi-cephfsplugin-xxxxx (on each node)                   3/3     Running
csi-rbdplugin-provisioner-xxxxxxxxxx-xxxxx              7/7     Running
csi-rbdplugin-xxxxx (on each node)                      3/3     Running
```

---

## Post-Installation Configuration

### 1. Verify Cluster Health

```bash
# Check cluster status
kubectl -n rook-ceph get cephcluster

# Should show HEALTH_OK after 5-10 minutes
# NAME        DATADIRHOSTPATH   MONCOUNT   AGE   PHASE   MESSAGE                 HEALTH
# rook-ceph   /var/lib/rook     3          10m   Ready   Cluster created successfully  HEALTH_OK

# Check from toolbox
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status

# Expected output:
#   cluster:
#     id:     xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#     health: HEALTH_OK
#   services:
#     mon: 3 daemons, quorum a,b,c
#     mgr: a(active), b(standby)
#     osd: 3 osds: 3 up, 3 in
```

### 2. Enable Orchestrator

```bash
# Enable Rook orchestrator module
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- bash -c "
  ceph mgr module enable rook
  ceph orch set backend rook
  ceph orch status
"

# Should show:
# Backend: rook
# Available: Yes
```

### 3. Create Dashboard User

```bash
# Create admin user for dashboard
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph dashboard ac-user-create admin 'YourSecurePassword123!' administrator

# Verify user created
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph dashboard ac-user-show admin
```

---

## Verification

### Health Checks

```bash
# 1. Cluster health
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph health detail

# 2. OSD status
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree

# 3. Storage capacity
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph df

# 4. Pool status
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd pool ls detail

# 5. Check storage class
kubectl get storageclass rook-ceph-block
```

### Test PVC Creation

```bash
# Create test PVC
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-rook-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: rook-ceph-block
  resources:
    requests:
      storage: 1Gi
EOF

# Wait for PVC to bind
kubectl get pvc test-rook-pvc -w

# Should show:
# NAME            STATUS   VOLUME                                     CAPACITY
# test-rook-pvc   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   1Gi

# Test with pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  namespace: default
spec:
  containers:
  - name: test
    image: busybox
    command: ["sleep", "3600"]
    volumeMounts:
    - name: test-vol
      mountPath: /data
  volumes:
  - name: test-vol
    persistentVolumeClaim:
      claimName: test-rook-pvc
EOF

# Verify pod is running
kubectl get pod test-pod

# Test write
kubectl exec test-pod -- sh -c "echo 'Hello Ceph' > /data/test.txt"
kubectl exec test-pod -- cat /data/test.txt

# Cleanup
kubectl delete pod test-pod
kubectl delete pvc test-rook-pvc
```

---

## Storage Class Configuration

### Default Block Storage Class

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-ceph-block
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  clusterID: rook-ceph
  pool: replicapool
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
  csi.storage.k8s.io/fstype: ext4
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
```

### High-Performance SSD Pool (Optional)

```yaml
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: ssd-pool
  namespace: rook-ceph
spec:
  failureDomain: host
  replicated:
    size: 3
  deviceClass: ssd
  parameters:
    compression_mode: none  # Disable for max performance
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-ceph-block-ssd
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  clusterID: rook-ceph
  pool: ssd-pool
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
  csi.storage.k8s.io/fstype: ext4
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
```

---

## Dashboard Access

### Via Port-Forward (Quick Access)

```bash
# Get dashboard password
DASHBOARD_PASSWORD=$(kubectl -n rook-ceph get secret rook-ceph-dashboard-password \
  -o jsonpath="{['data']['password']}" | base64 --decode)

echo "Dashboard Password: $DASHBOARD_PASSWORD"

# Port-forward dashboard
kubectl -n rook-ceph port-forward svc/rook-ceph-mgr-dashboard 7000:7000

# Access at: http://localhost:7000
# Username: admin
# Password: <from above>
```

### Via Ingress (Production)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ceph-dashboard
  namespace: rook-ceph
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"  # If using cert-manager
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ceph-dashboard.example.com
      secretName: ceph-dashboard-tls
  rules:
    - host: ceph-dashboard.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: rook-ceph-mgr-dashboard
                port:
                  number: 7000
```

---

## Troubleshooting

### Common Issues

#### 1. OSDs Not Starting

```bash
# Check OSD prepare logs
kubectl -n rook-ceph logs -l app=rook-ceph-osd-prepare

# Check if disks are clean
# SSH to node and run:
lsblk -f
# Disks should have NO filesystem

# Clean disk if needed
sudo wipefs -af /dev/sdb
sudo sgdisk --zap-all /dev/sdb
```

#### 2. MONs Not Forming Quorum

```bash
# Check MON logs
kubectl -n rook-ceph logs -l app=rook-ceph-mon

# Verify time sync across nodes
for node in worker-node-1 worker-node-2 worker-node-3; do
    ssh $node "date +%s"
done
# Times should be within 1 second
```

#### 3. Cluster Stuck in HEALTH_WARN

```bash
# Check detailed health
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph health detail

# Common warnings and fixes:
# - "clock skew detected" → Fix NTP/chrony
# - "too many PGs per OSD" → Wait for pg_autoscaler
# - "mon is allowing insecure global_id reclaim" → Wait or run:
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph config set mon auth_allow_insecure_global_id_reclaim false
```

#### 4. CSI Pods CrashLooping

```bash
# Check CSI logs
kubectl -n rook-ceph logs -l app=csi-rbdplugin

# Common issue: Missing ConfigMap
kubectl get configmap rook-ceph-csi-kms-config -n rook-ceph

# If missing, create it (see Installation section)
```

#### 5. PVC Stuck in Pending

```bash
# Describe PVC
kubectl describe pvc <pvc-name>

# Check events
kubectl get events --sort-by='.lastTimestamp' | grep <pvc-name>

# Check CSI provisioner logs
kubectl -n rook-ceph logs -l app=csi-rbdplugin-provisioner
```

### Debug Commands

```bash
# Enter toolbox for debugging
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- bash

# Inside toolbox:
ceph status              # Overall health
ceph osd tree            # OSD hierarchy
ceph osd df              # OSD disk usage
ceph df                  # Cluster capacity
ceph health detail       # Detailed health
ceph mon stat            # Monitor status
ceph mgr services        # Manager services
ceph versions            # Component versions
```

---

## Maintenance

### Backup and Disaster Recovery

```bash
# Backup Ceph configuration
kubectl -n rook-ceph get cephcluster rook-ceph -o yaml > cephcluster-backup.yaml

# Backup secrets
kubectl -n rook-ceph get secrets -o yaml > ceph-secrets-backup.yaml

# Create volume snapshots
kubectl create -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: my-snapshot
  namespace: default
spec:
  volumeSnapshotClassName: rook-ceph-block
  source:
    persistentVolumeClaimName: my-pvc
EOF
```

### Scaling

**Add Storage Node:**

```bash
# 1. Prepare new node (follow Pre-Installation Setup)
# 2. Label node
kubectl label nodes worker-node-4 storage=ceph

# 3. Update CephCluster
kubectl edit cephcluster rook-ceph -n rook-ceph

# Add under storage.nodes:
#   - name: "worker-node-4"
#     devices:
#       - name: "/dev/disk/by-id/ata-NewDisk-Serial"
```

**Add Disk to Existing Node:**

```bash
# 1. Prepare disk on node
# 2. Update CephCluster
kubectl edit cephcluster rook-ceph -n rook-ceph

# Add disk under existing node's devices list
#   - name: "/dev/disk/by-id/ata-AdditionalDisk-Serial"
```

### Upgrade

```bash
# Upgrade operator
helm upgrade rook-ceph rook-release/rook-ceph \
  -f rook-ceph-operator-values.yaml \
  -n rook-ceph

# Upgrade cluster
helm upgrade rook-ceph-cluster rook-release/rook-ceph-cluster \
  -f rook-ceph-cluster-values.yaml \
  -n rook-ceph

# Monitor upgrade progress
watch kubectl -n rook-ceph get pods
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
```

### Monitoring

```bash
# Check cluster metrics
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph df

# Monitor I/O
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph iostat

# Check OSD performance
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd perf
```

---

## Additional Resources

- **Rook Documentation**: https://rook.io/docs/rook/latest/
- **Ceph Documentation**: https://docs.ceph.com/
- **Troubleshooting Guide**: https://rook.io/docs/rook/latest/Troubleshooting/ceph-common-issues/
- **GitHub Issues**: https://github.com/rook/rook/issues

---

## License

This deployment guide is provided as-is for use in deploying Rook-Ceph on Kubernetes clusters.

## Contributing

Contributions and improvements to this guide are welcome. Please test thoroughly before submitting changes.

---

**Last Updated**: January 2026  
**Tested On**: RKE2 v1.27+, Rook v1.19.0, Ceph v19.2.3