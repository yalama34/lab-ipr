set -e
BASE="https://raw.githubusercontent.com/ctrox/csi-s3/master/deploy/kubernetes"

echo "Applying ctrox/csi-s3 manifests..."
kubectl apply -f "${BASE}/provisioner.yaml"
kubectl apply -f "${BASE}/attacher.yaml"
kubectl apply -f "${BASE}/csi-s3.yaml"

echo "Patching csi-s3 DaemonSet: dnsPolicy=ClusterFirstWithHostNet..."
kubectl patch daemonset csi-s3 -n kube-system --type=strategic -p \
  '{"spec":{"template":{"spec":{"dnsPolicy":"ClusterFirstWithHostNet"}}}}'

echo "Replacing sidecar images (sig-storage)..."
kubectl set image statefulset/csi-attacher-s3 -n kube-system \
  csi-attacher=registry.k8s.io/sig-storage/csi-attacher:v4.6.1
kubectl set image statefulset/csi-provisioner-s3 -n kube-system \
  csi-provisioner=registry.k8s.io/sig-storage/csi-provisioner:v5.0.1
kubectl set image daemonset/csi-s3 -n kube-system \
  driver-registrar=registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.11.1

echo "Waiting for rollout..."
kubectl rollout status statefulset/csi-attacher-s3 -n kube-system --timeout=180s
kubectl rollout status statefulset/csi-provisioner-s3 -n kube-system --timeout=180s
kubectl rollout status daemonset/csi-s3 -n kube-system --timeout=300s

echo "Done."