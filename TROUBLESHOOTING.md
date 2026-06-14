# Troubleshooting Guide

## Installation & Prerequisites

### "command not found: minikube" or "command not found: kubectl"

The `01-install-prerequisites.sh` script installs tools via Homebrew. If it failed:

```bash
chmod +x scripts/01-install-prerequisites.sh
./scripts/01-install-prerequisites.sh
```

Or manually install:
```bash
brew install minikube kubectl helm kyverno-cli cosign crane jq
```

### "Docker Desktop is not running"

Start Docker Desktop before running the cluster setup:
```bash
open /Applications/Docker.app
```

Wait for the "Docker Desktop is running" message in the menu bar.

### "Minikube failed to start" or "Error allocating requested resources"

Minikube needs ~6GB RAM. Check your available memory:

```bash
# macOS
vm_memory=$(sysctl hw.memsize | awk '{print $2 / 1024 / 1024 / 1024}')
echo "Available memory: ${vm_memory}GB"
```

If under 8GB total, try:
- Closing unused applications
- Reducing Docker Desktop's memory limit in **Preferences → Resources → Memory**
- Running `./scripts/05-teardown.sh` to free the previous cluster's memory

### "Homebrew: command not found"

Install Homebrew first:
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

---

## Cluster Setup Issues

### "Error: registry addon not enabled"

The `02-start-cluster.sh` script enables the registry addon. If it didn't activate:

```bash
minikube addons enable registry -p kyverno-demo
```

Verify:
```bash
minikube addons list -p kyverno-demo | grep registry
```

### "Port forwarding failed for registry"

If the registry port-forward dies unexpectedly:

```bash
# Kill existing port-forwards
killall -9 kubectl

# Restart the forward manually
kubectl port-forward -n kube-system svc/registry 5000:80
```

### "Kyverno pod is in CrashLoopBackOff"

Check the logs:
```bash
kubectl logs -n kyverno deploy/kyverno-admission-controller -f
```

Common causes:
- **Insufficient memory** — the cluster needs at least 6GB
- **RBAC issues** — check if the Kyverno ServiceAccount has the right permissions:
  ```bash
  kubectl get rolebindings,clusterrolebindings -n kyverno | grep kyverno
  ```
- **Webhook misconfiguration** — check the ValidatingWebhookConfiguration:
  ```bash
  kubectl get validatingwebhookconfigurations
  kubectl describe validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg
  ```

**Fix:** Delete and reinstall Kyverno:
```bash
helm uninstall kyverno -n kyverno
./scripts/02-start-cluster.sh
```

---

## App Deployment Issues

### "Error building Docker image"

The `03-deploy-app.sh` script builds images using `docker build`. Ensure:
1. Docker Desktop is running
2. You have enough disk space: `docker system df`
3. Dockerfile is valid: `cat apps/team-stats-api/Dockerfile`

**Fix:** Clean up old images and retry:
```bash
docker system prune -a --volumes
./scripts/03-deploy-app.sh
```

### "Error pushing image: context deadline exceeded"

This typically means `crane` failed to reach the registry. Check:

```bash
# Get the actual host port for the registry
REGISTRY_PORT=$(kubectl get service -n kube-system registry -o jsonpath='{.spec.ports[0].nodePort}')
echo "Registry at: localhost:$REGISTRY_PORT"

# Test connectivity
curl -s http://localhost:$REGISTRY_PORT/v2/ | jq .
```

If that fails, restart the port-forward:
```bash
killall -9 kubectl
kubectl port-forward -n kube-system svc/registry 5000:80 &
sleep 2
curl -s http://localhost:5000/v2/ | jq .
```

### "Cosign signature verification failed"

The script patches `kyverno/08-verify-image-signatures.yaml` with the public key. If verification fails:

1. Verify the public key was injected:
   ```bash
   grep -A 10 "publicKeys:" kyverno/08-verify-image-signatures.yaml
   ```

2. Verify the image was actually signed:
   ```bash
   cosign verify --key cosign/cosign.pub --insecure-ignore-tlog \
       localhost:5000/team-stats-api:v1
   ```

3. If the key is missing, regenerate and re-patch:
   ```bash
   rm cosign/cosign.key cosign/cosign.pub
   ./scripts/03-deploy-app.sh
   ```

---

## Demo Scenario Issues

### "Admission webhook not responding"

The webhook might still be starting. Wait a few seconds:

```bash
kubectl get pods -n kyverno
# Wait for all pods to be Running + Ready (2/2)
kubectl wait --for=condition=ready pod -n kyverno -l app=kyverno -l component=admission-controller --timeout=120s
```

Then retry the scenario.

### "Policy application timed out"

If `kubectl apply` hangs:

```bash
# Kill the stuck kubectl
killall -9 kubectl

# Check if the webhook is alive
kubectl logs -n kyverno deploy/kyverno-admission-controller | tail -50
```

**Fix:** Restart the admission controller:
```bash
kubectl rollout restart deployment/kyverno-admission-controller -n kyverno
kubectl wait --for=condition=ready pod -n kyverno -l app=kyverno -l component=admission-controller --timeout=120s
```

### "Bad pod was admitted when it should have been rejected"

Verify the policy is actually applied:

```bash
kubectl get clusterpolicy
kubectl describe clusterpolicy <policy-name>
```

Check if the webhook is catching the request:
```bash
kubectl logs -n kyverno deploy/kyverno-admission-controller -f
# Then try applying the bad pod again in another terminal
```

### "Compliant pod (team-stats-api) was rejected"

Check what policy rejected it:

```bash
kubectl describe pod <pod-name> -n kyverno-demo
```

Look for events. Common causes:
- Policy regex is too broad (e.g., blocking all images, not just specific ones)
- Compliant pod is missing a required label
- Cosign signature changed (regenerate keys and re-sign)

---

## Policy Report Issues

### "No policyreports found"

Policy reports are generated by background scans. They take a minute or two to appear:

```bash
# Check if background-scan is running
kubectl get pods -n kyverno | grep background

# Wait for scans to run
sleep 90
kubectl get policyreport -A
```

### "Policy Reporter UI is blank or slow"

The UI queries policyreports from the cluster. If it's slow:

1. Check the UI pod logs:
   ```bash
   kubectl logs -n policy-reporter -l app=policy-reporter-ui -f
   ```

2. Check backend connectivity:
   ```bash
   kubectl exec -n policy-reporter <ui-pod> -it -- curl http://localhost:8080/api/policyreports
   ```

3. Restart the UI:
   ```bash
   kubectl rollout restart deployment/policy-reporter-ui -n policy-reporter
   ```

---

## Cleanup & Removal

### "Teardown script failed"

If `05-teardown.sh` fails midway:

```bash
# Manually clean up remaining resources
kubectl delete clusterpolicy --all
kubectl delete clustercleanuppolicy --all
helm uninstall kyverno -n kyverno
helm uninstall policy-reporter -n policy-reporter

# Delete the cluster
minikube delete -p kyverno-demo

# Kill remaining port-forwards
killall -9 kubectl
```

### "Cluster is stuck in a weird state"

Nuclear option (destroys everything):
```bash
./scripts/05-teardown.sh
minikube delete -p kyverno-demo --purge
killall -9 kubectl
rm -rf ~/.minikube/profiles/kyverno-demo
rm -rf ~/.minikube/machines/kyverno-demo
```

Then start fresh:
```bash
./scripts/02-start-cluster.sh
./scripts/03-deploy-app.sh
```

---

## Getting More Help

### Enable Debug Logging

For Kyverno:
```bash
kubectl set env deployment/kyverno-admission-controller -n kyverno LOG_LEVEL=debug
kubectl logs -n kyverno deploy/kyverno-admission-controller -f
```

For scripts (bash):
```bash
bash -x scripts/04-demo-scenarios.sh 2>&1 | tee debug.log
```

For Kubernetes API calls:
```bash
kubectl --v=8 get pods  # 0-10, higher = more verbose
```

### Collect Diagnostics

```bash
# Minikube status
minikube status -p kyverno-demo
minikube logs -p kyverno-demo --tail=100

# Cluster info
kubectl cluster-info dump --output-directory=./cluster-dump

# Kyverno status
kubectl get all -n kyverno
kubectl describe clusterpolicies
kubectl logs -n kyverno --all-containers=true --tail=100
```

### Report a Bug

If you can't solve it, open an issue on GitHub with:
1. The exact command that failed
2. The error message
3. Output of the diagnostics above
4. Your system info: `uname -a`, `minikube version`, `kubectl version`

---

## Quick Reference

| Issue | Command |
|-------|---------|
| Kyverno logs | `kubectl logs -n kyverno deploy/kyverno-admission-controller -f` |
| All cluster policies | `kubectl get clusterpolicy` |
| All policy reports | `kubectl get policyreport -A` |
| Restart Kyverno | `kubectl rollout restart deployment/kyverno-admission-controller -n kyverno` |
| Check webhook | `kubectl get validatingwebhookconfigurations` |
| Test a policy | `kyverno apply kyverno/04-pod-security-restricted.yaml --resource k8s/bad-pods/01-runs-as-root.yaml` |
| Kill stuck port-forwards | `killall -9 kubectl` |
| Delete cluster | `minikube delete -p kyverno-demo` |

---

Still stuck? Check the [Kyverno docs](https://kyverno.io/docs/) or open an issue! 🛡️
