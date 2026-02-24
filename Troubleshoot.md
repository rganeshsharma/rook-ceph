helm install --namespace rook-ceph rook-ceph-cluster \
   --set operatorNamespace=rook-ceph --set image.pullPolicy=IfNotPresent rook-release/rook-ceph-cluster -f override-values.yml


kubectl patch cm rook-ceph-mon-endpoints \
  -n rook-ceph \
  --type=json \
  -p='[{"op":"remove","path":"/metadata/finalizers"}]'


Next steps:
Clean up host storage on each node:
     sudo rm -rf /var/lib/rook
     sudo wipefs -af /dev/sdb
     sudo sgdisk --zap-all /dev/sdb


cephClusterSpec:
  storage:
    useAllNodes: false
    useAllDevices: false
    nodes:
      - name: "worker-node-1"
        devices:
          - name: "/dev/disk/by-id/ata-WDC_WD1003FZEX-00MK2A0_WD-XXX1234"
          - name: "/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL567890"
      - name: "worker-node-2"
        devices:
          - name: "/dev/disk/by-id/ata-WDC_WD1003FZEX-00MK2A0_WD-YYY5678"
          - name: "/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL098765"
      - name: "worker-node-3"
        devices:
          - name: "/dev/disk/by-id/ata-WDC_WD1003FZEX-00MK2A0_WD-ZZZ9012"