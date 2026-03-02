# Ceph Storage Apps + Velero Backup Guide
## RKE2 + Rook-Ceph + Velero on Government Infrastructure

---

## Directory Structure

```
ceph-velero-demo/
├── app1-cephfs/
│   ├── 01-namespace.yaml           # demo-cephfs namespace
│   ├── 02-pvc.yaml                 # CephFS RWX PVC (2Gi)
│   ├── 03-configmap.yaml           # Init script
│   ├── 04-deployment.yaml          # nginx + Service (2 replicas using RWX)
│   └── 05-data-writer-job.yaml     # Writes test data for backup verification
│
├── app2-bucket/
│   ├── 01-namespace.yaml           # demo-bucket namespace
│   ├── 02-objectbucketclaim.yaml   # OBC → Ceph RGW provisions S3 bucket
│   ├── 03-deployment.yaml          # aws-cli app writing objects to bucket
│   ├── 04-verify-job.yaml          # Lists bucket contents for verification
│   └── 05-bucket-backup-cronjob.yaml  # rclone sync for actual S3 objects
│
└── velero-backup/
    ├── 01-volume-snapshot-classes.yaml  # VolumeSnapshotClass for CephFS + RBD
    ├── 02-backup-schedules.yaml         # Velero Schedule CRDs
    └── 03-backup-restore-procedures.sh # All backup/restore commands
```

---

## Step 1: Verify Your StorageClass Names

```bash
kubectl get storageclass
# You need these (adjust names in manifests if different):
#   rook-cephfs        ← for App1 PVC
#   rook-ceph-bucket   ← for App2 OBC
```

---

## Step 2: Install CSI Snapshot Controller (if not present)

```bash
# Check if already installed
kubectl get crd volumesnapshotclasses.snapshot.storage.k8s.io

# If not, install snapshot controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v7.0.2/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v7.0.2/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v7.0.2/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v7.0.2/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v7.0.2/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
```

---

## Step 3: Enable Velero CSI Plugin

```bash
# Check if CSI plugin is present
velero plugin get | grep csi

# If not present, add it
velero plugin add velero/velero-plugin-for-csi:v0.7.0

# Verify Velero server has EnableCSI feature flag
kubectl get deployment -n velero velero -o yaml | grep features
# Should show: --features=EnableCSI
```

---

## Step 4: Apply VolumeSnapshotClasses

```bash
kubectl apply -f velero-backup/01-volume-snapshot-classes.yaml

# Verify Velero can find them
kubectl get volumesnapshotclass -l velero.io/csi-volumesnapshot-class=true
```

---

## Step 5: Deploy App1 (CephFS)

```bash
kubectl apply -f app1-cephfs/

# Wait for PVC to bind
kubectl get pvc -n demo-cephfs -w
# Should show: cephfs-pvc   Bound   ...   rook-cephfs

# Wait for pods to be ready
kubectl get pods -n demo-cephfs -w

# Run data writer to populate test data
kubectl apply -f app1-cephfs/05-data-writer-job.yaml
kubectl logs -n demo-cephfs job/cephfs-data-writer

# Verify data on PVC
kubectl exec -n demo-cephfs deploy/cephfs-nginx -- ls -la /data/backup-test/
```

---

## Step 6: Deploy App2 (Bucket)

```bash
kubectl apply -f app2-bucket/01-namespace.yaml
kubectl apply -f app2-bucket/02-objectbucketclaim.yaml

# Wait for OBC to be provisioned (Ceph RGW creates the bucket)
kubectl get obc -n demo-bucket -w
# Should show: demo-app-bucket   rook-ceph-bucket   demo-app-bucket   Bound

# Verify Secret and ConfigMap were auto-created by OBC provisioner
kubectl get secret demo-app-bucket -n demo-bucket
kubectl get configmap demo-app-bucket -n demo-bucket
kubectl get configmap demo-app-bucket -n demo-bucket -o yaml
# Shows: BUCKET_HOST, BUCKET_PORT, BUCKET_NAME

# Deploy the app
kubectl apply -f app2-bucket/03-deployment.yaml
kubectl apply -f app2-bucket/04-verify-job.yaml
kubectl apply -f app2-bucket/05-bucket-backup-cronjob.yaml

# Watch the app writing to the bucket
kubectl logs -n demo-bucket deploy/bucket-app -f

# Verify bucket objects
kubectl logs -n demo-bucket job/bucket-verify
```

---

## Step 7: Run Backups

```bash
# Apply schedules (or run manually for testing)
kubectl apply -f velero-backup/02-backup-schedules.yaml

# Manual backup - App1 CephFS
velero backup create cephfs-test-backup \
  --include-namespaces demo-cephfs \
  --snapshot-volumes \
  --default-volumes-to-fs-backup=false \
  --wait

# Verify CSI snapshot was created
kubectl get volumesnapshot -n demo-cephfs
# Should show a VolumeSnapshot object created by Velero

# Manual backup - App2 Bucket
velero backup create bucket-test-backup \
  --include-namespaces demo-bucket \
  --snapshot-volumes=false \
  --wait

# Check both backups
velero backup get
velero backup describe cephfs-test-backup --details
```

---

## Step 8: Test Restore

```bash
# --- CephFS Restore Test ---
# Delete the namespace to simulate disaster
kubectl delete namespace demo-cephfs

# Restore from backup
velero restore create cephfs-restore-test \
  --from-backup cephfs-test-backup \
  --restore-volumes \
  --wait

# Verify data survived
kubectl exec -n demo-cephfs deploy/cephfs-nginx -- \
  cat /data/backup-test/manifest.txt

# --- Bucket App Restore Test ---
kubectl delete namespace demo-bucket

velero restore create bucket-restore-test \
  --from-backup bucket-test-backup \
  --wait

# OBC recreated → new empty bucket
# Must re-sync data from rclone backup
# See 03-backup-restore-procedures.sh restore_bucket_data()
```

---

## Key Understanding: What Velero Backs Up

| Storage Type | k8s Resources | PVC Data | Bucket Objects |
|---|---|---|---|
| **CephFS PVC** | ✅ Full | ✅ CSI Snapshot | N/A |
| **Ceph Bucket (OBC)** | ✅ OBC + Secret + CM | N/A | ❌ Use rclone |

### Why Bucket Objects Need rclone

Velero works at the Kubernetes storage layer (PVs/PVCs). S3 bucket objects are accessed via the S3 API and stored inside Ceph RADOS — there's no PVC, so Velero has nothing to snapshot. The rclone CronJob bridges this gap by syncing objects to MinIO (which is already your Velero backend).

### Velero CSI Snapshot Flow for CephFS

```
velero backup create
  └── Velero finds PVC → checks for labeled VolumeSnapshotClass
      └── Creates VolumeSnapshot object in k8s
          └── CSI driver (cephfs.csi.ceph.com) calls Ceph snapshot API
              └── Ceph creates point-in-time snapshot of the CephFS volume
                  └── Velero uploads VolumeSnapshotContent metadata to MinIO
                      └── On restore: new PVC created from snapshot
```
