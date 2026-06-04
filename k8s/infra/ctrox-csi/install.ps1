$ErrorActionPreference = "Stop"

$base = "https://raw.githubusercontent.com/ctrox/csi-s3/master/deploy/kubernetes"

Write-Host "Applying ctrox/csi-s3 manifests..."
kubectl apply -f "$base/provisioner.yaml"
kubectl apply -f "$base/attacher.yaml"
kubectl apply -f "$base/csi-s3.yaml"

Write-Host "Patching csi-s3 DaemonSet: dnsPolicy=ClusterFirstWithHostNet..."
# Windows: не использовать -p '{...}' (ломает разбор JSON) и не полагаться на BOM в файлах репозитория.
# RFC6902 JSON Patch во временном файле, UTF-8 без BOM.
$jsonPatch = '[{"op":"replace","path":"/spec/template/spec/dnsPolicy","value":"ClusterFirstWithHostNet"}]'
$tmp = [System.IO.Path]::Combine(
  [System.IO.Path]::GetTempPath(),
  ("k8s-csi-s3-dnsPatch-" + [Guid]::NewGuid().ToString() + ".json"))
$enc = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($tmp, $jsonPatch, $enc)
try {
  kubectl patch daemonset csi-s3 -n kube-system --type=json --patch-file="$tmp"
  if ($LASTEXITCODE -ne 0) { throw "kubectl patch exited $LASTEXITCODE" }
}
finally {
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
$policy = kubectl get ds csi-s3 -n kube-system -o jsonpath="{.spec.template.spec.dnsPolicy}"
if ($policy -ne "ClusterFirstWithHostNet") {
  throw "csi-s3 dnsPolicy is '$policy', expected ClusterFirstWithHostNet"
}

Write-Host "Replacing sidecar images (sig-storage)..."
kubectl set image statefulset/csi-attacher-s3 -n kube-system csi-attacher=registry.k8s.io/sig-storage/csi-attacher:v4.6.1
kubectl set image statefulset/csi-provisioner-s3 -n kube-system csi-provisioner=registry.k8s.io/sig-storage/csi-provisioner:v5.0.1
kubectl set image daemonset/csi-s3 -n kube-system driver-registrar=registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.11.1

Write-Host "Restarting CSI workload..."
kubectl rollout status statefulset/csi-attacher-s3 -n kube-system --timeout=180s
kubectl rollout status statefulset/csi-provisioner-s3 -n kube-system --timeout=180s
kubectl rollout status daemonset/csi-s3 -n kube-system --timeout=300s

Write-Host "Done. Apply CSIDriver from k8s/base/csi.yaml if not yet: kubectl apply -k k8s/overlays/dev"