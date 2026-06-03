#!/usr/bin/env bash
# Interactive demo walkthrough for Kyverno in Action.
set -euo pipefail

NAMESPACE="kyverno-demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
POLICY_REPORTER_NS="policy-reporter"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[FAIL]${NC} $*"; }
section() { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

pause() {
    echo ""
    read -rp "  Press ENTER to continue... "
    echo ""
}

cleanup_policies() {
    info "Cleaning up Kyverno policies from previous scenario..."
    kubectl delete clusterpolicy --all 2>/dev/null || true
    kubectl delete clustercleanuppolicy --all 2>/dev/null || true
    sleep 2
}

cleanup_bad_pods() {
    info "Cleaning up bad pods from previous scenario..."
    kubectl delete pod -n "$NAMESPACE" -l app=trash-talk-bot --ignore-not-found 2>/dev/null || true
    sleep 1
}

apply_expect_fail() {
    local file=$1
    local reason=$2
    if kubectl apply -f "$file" 2>&1 | tee /tmp/kyverno-apply.out | grep -qE "Error|denied|blocked"; then
        info "✅ Rejected by Kyverno — $reason"
        grep -E "Error|denied|message" /tmp/kyverno-apply.out | head -3 | sed 's/^/    /'
    else
        error "❌ Expected rejection but pod was admitted: $file"
    fi
}

apply_expect_succeed() {
    local file=$1
    local reason=$2
    if kubectl apply -f "$file" 2>&1 | grep -qE "created|configured|unchanged"; then
        info "✅ Admitted — $reason"
    else
        error "❌ Expected admission but Kyverno rejected: $file"
    fi
}

echo ""
echo "================================================"
echo "  🛡️  Kyverno in Action — Demo Scenarios"
echo "================================================"
echo ""
echo "  Prereqs: 02-start-cluster.sh + 03-deploy-app.sh have run."
echo "  Optional: kubectl port-forward svc/team-stats-api 9080:8080 -n $NAMESPACE"
echo ""
pause

# ─────────────────────────────────────────────────────────────
section "Scenario 1: Baseline — The Arena Has No Bouncers"
# ─────────────────────────────────────────────────────────────

cleanup_policies
cleanup_bad_pods

info "No Kyverno policies applied. Every rogue pod is admitted."
echo ""
for f in 03-missing-labels 02-uses-latest-tag 04-no-resources; do
    apply_expect_succeed "$PROJECT_DIR/k8s/bad-pods/$f.yaml" "$f got in (no policies)"
done
warn "All three rogue pods are now running. That's the problem."
pause

# ─────────────────────────────────────────────────────────────
section "Scenario 2: Require Labels — Team Jerseys at the Door"
# ─────────────────────────────────────────────────────────────

cleanup_policies
cleanup_bad_pods

info "Applying kyverno/01-require-labels.yaml..."
kubectl apply -f "$PROJECT_DIR/kyverno/01-require-labels.yaml"
sleep 3

apply_expect_fail "$PROJECT_DIR/k8s/bad-pods/03-missing-labels.yaml" "missing team + env labels"
echo ""
apply_expect_succeed "$PROJECT_DIR/k8s/team-stats-api.yaml" "team-stats-api has labels"
pause

# ─────────────────────────────────────────────────────────────
section "Scenario 3: No :latest — No Undrafted Players"
# ─────────────────────────────────────────────────────────────

cleanup_policies
cleanup_bad_pods

info "Applying kyverno/02-disallow-latest-tag.yaml..."
kubectl apply -f "$PROJECT_DIR/kyverno/02-disallow-latest-tag.yaml"
sleep 3

apply_expect_fail "$PROJECT_DIR/k8s/bad-pods/02-uses-latest-tag.yaml" "uses :latest"
pause

# ─────────────────────────────────────────────────────────────
section "Scenario 4: Require Resources — No Unlimited Minutes"
# ─────────────────────────────────────────────────────────────

cleanup_policies
cleanup_bad_pods

info "Applying kyverno/03-require-resources.yaml..."
kubectl apply -f "$PROJECT_DIR/kyverno/03-require-resources.yaml"
sleep 3

apply_expect_fail "$PROJECT_DIR/k8s/bad-pods/04-no-resources.yaml" "no requests/limits"
pause

# ─────────────────────────────────────────────────────────────
section "Scenario 5: Pod Security Restricted — Locker Room Rules"
# ─────────────────────────────────────────────────────────────

cleanup_policies
cleanup_bad_pods

info "Applying kyverno/04-pod-security-restricted.yaml..."
kubectl apply -f "$PROJECT_DIR/kyverno/04-pod-security-restricted.yaml"
sleep 3

apply_expect_fail "$PROJECT_DIR/k8s/bad-pods/01-runs-as-root.yaml"   "runs as root (UID 0)"
echo ""
apply_expect_fail "$PROJECT_DIR/k8s/bad-pods/05-host-path.yaml"      "mounts hostPath /"
echo ""
apply_expect_fail "$PROJECT_DIR/k8s/bad-pods/06-privileged.yaml"     "privileged container"
pause

# ─────────────────────────────────────────────────────────────
section "Scenario 6: Mutate — The Coach Adjusts the Lineup"
# ─────────────────────────────────────────────────────────────

cleanup_policies
cleanup_bad_pods

info "Applying mutate policies 05 + 06..."
kubectl apply -f "$PROJECT_DIR/kyverno/05-mutate-default-pull-policy.yaml"
kubectl apply -f "$PROJECT_DIR/kyverno/06-mutate-add-default-labels.yaml"
sleep 3

info "Applying a pod with no env label and no pullPolicy..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: trash-talk-mutated
  namespace: $NAMESPACE
  labels:
    app: trash-talk-bot
    team: hawks
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
  containers:
    - name: bot
      image: localhost:5000/trash-talk-bot:v1
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      resources:
        requests: { cpu: 50m, memory: 64Mi }
        limits:   { cpu: 100m, memory: 128Mi }
EOF
sleep 2
info "Inspecting the mutated pod — Kyverno injected env label + imagePullPolicy:"
kubectl get pod trash-talk-mutated -n "$NAMESPACE" \
    -o jsonpath='{"  labels: "}{.metadata.labels}{"\n  imagePullPolicy: "}{.spec.containers[0].imagePullPolicy}{"\n"}'
pause

# ─────────────────────────────────────────────────────────────
section "Scenario 7: Generate — New Franchise Setup"
# ─────────────────────────────────────────────────────────────

cleanup_policies
cleanup_bad_pods
kubectl delete namespace tenant-hawks --ignore-not-found --wait=true 2>/dev/null || true

info "Applying kyverno/07-generate-tenant-defaults.yaml..."
kubectl apply -f "$PROJECT_DIR/kyverno/07-generate-tenant-defaults.yaml"
sleep 3

info "Creating tenant-hawks namespace (label: tenant=hawks)..."
kubectl apply -f "$PROJECT_DIR/k8s/tenant-namespace.yaml"
sleep 4

info "Resources Kyverno generated inside tenant-hawks:"
echo ""
echo "  NetworkPolicy:"
kubectl get networkpolicy -n tenant-hawks
echo ""
echo "  ResourceQuota:"
kubectl get resourcequota -n tenant-hawks
echo ""
echo "  LimitRange:"
kubectl get limitrange -n tenant-hawks
pause

# ─────────────────────────────────────────────────────────────
section "Scenario 8: Verify Image Signatures — Player ID Check"
# ─────────────────────────────────────────────────────────────

cleanup_policies
cleanup_bad_pods

info "Applying kyverno/08-verify-image-signatures.yaml (Cosign)..."
kubectl apply -f "$PROJECT_DIR/kyverno/08-verify-image-signatures.yaml"
sleep 3

info "Compliant app (team-stats-api is signed) should be admitted on re-apply..."
apply_expect_succeed "$PROJECT_DIR/k8s/team-stats-api.yaml" "team-stats-api Cosign signature valid"
echo ""
info "Unsigned image (trash-talk-bot) should be rejected..."
apply_expect_fail "$PROJECT_DIR/k8s/bad-pods/07-unsigned-image.yaml" "no Cosign signature"
pause

# ─────────────────────────────────────────────────────────────
section "Scenario 9: Cleanup — End-of-Game Locker Clear-Out"
# ─────────────────────────────────────────────────────────────

cleanup_policies
cleanup_bad_pods

info "Applying kyverno/09-cleanup-old-pods.yaml..."
kubectl apply -f "$PROJECT_DIR/kyverno/09-cleanup-old-pods.yaml"
sleep 3

info "Running a quick Job that exits immediately..."
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: cleanup-demo
  namespace: $NAMESPACE
  labels:
    team: platform
    env: demo
spec:
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels:
        team: platform
        env: demo
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
      containers:
        - name: done
          image: localhost:5000/trash-talk-bot:v1
          imagePullPolicy: IfNotPresent
          command: ["python", "-c", "print('game over')"]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 100m, memory: 128Mi }
EOF

info "Waiting for Job to finish, then for cleanup-controller to sweep..."
kubectl wait --for=condition=complete job/cleanup-demo -n "$NAMESPACE" --timeout=60s
info "Watching: completed pod should disappear within ~60-90s (schedule */1)."
for i in 1 2 3; do
    sleep 30
    REMAINING=$(kubectl get pods -n "$NAMESPACE" -l job-name=cleanup-demo --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo "  t+${i}m: remaining completed pods = $REMAINING"
    if [[ "$REMAINING" == "0" ]]; then
        info "✅ cleanup-controller swept the completed pod."
        break
    fi
done
pause

# ─────────────────────────────────────────────────────────────
section "Scenario 10: Policy Reports — The Referee's Report"
# ─────────────────────────────────────────────────────────────

info "Re-applying all validate policies so background scans pick up violations..."
kubectl apply -f "$PROJECT_DIR/kyverno/01-require-labels.yaml"
kubectl apply -f "$PROJECT_DIR/kyverno/02-disallow-latest-tag.yaml"
kubectl apply -f "$PROJECT_DIR/kyverno/03-require-resources.yaml"
kubectl apply -f "$PROJECT_DIR/kyverno/04-pod-security-restricted.yaml"
sleep 5

info "Cluster-wide policy reports:"
kubectl get policyreport -A
echo ""
info "Failing rules in $NAMESPACE:"
kubectl get policyreport -n "$NAMESPACE" -o json 2>/dev/null | \
    python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for item in d.get('items', []):
        for r in item.get('results', []):
            if r.get('result') == 'fail':
                print(f\"  ❌ {r.get('policy')}/{r.get('rule')} → {r.get('message','')[:90]}\")
except Exception:
    pass
" || true
echo ""
info "Open the Policy Reporter UI:"
echo "    kubectl port-forward -n $POLICY_REPORTER_NS svc/policy-reporter-ui 8082:8080"
echo "    open http://localhost:8082"
pause

# ─────────────────────────────────────────────────────────────
section "Scenario 11: Full Baseline — Hardened End State"
# ─────────────────────────────────────────────────────────────

cleanup_policies
cleanup_bad_pods

info "Applying kyverno/10-full-baseline.yaml + 07 + 08 + 09..."
kubectl apply -f "$PROJECT_DIR/kyverno/10-full-baseline.yaml"
kubectl apply -f "$PROJECT_DIR/kyverno/07-generate-tenant-defaults.yaml"
kubectl apply -f "$PROJECT_DIR/kyverno/08-verify-image-signatures.yaml"
kubectl apply -f "$PROJECT_DIR/kyverno/09-cleanup-old-pods.yaml"
sleep 3

info "Compliant tenant app — should pass every rule:"
apply_expect_succeed "$PROJECT_DIR/k8s/team-stats-api.yaml" "team-stats-api: labels + pinned + resources + non-root + signed"
echo ""
info "Every bad pod — should be rejected by some rule:"
for f in 01-runs-as-root 02-uses-latest-tag 03-missing-labels 04-no-resources 05-host-path 06-privileged 07-unsigned-image; do
    apply_expect_fail "$PROJECT_DIR/k8s/bad-pods/$f.yaml" "$f"
done
echo ""
info "Active policies:"
kubectl get clusterpolicy,clustercleanuppolicy
echo ""

echo "================================================"
echo "  🏆 Demo complete!"
echo ""
echo "  Run ./scripts/05-teardown.sh when you're done."
echo "================================================"
