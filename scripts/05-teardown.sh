#!/usr/bin/env bash
# Tear everything down: delete namespaces, uninstall Kyverno + Policy Reporter,
# remove the Minikube profile, kill the registry port-forward.
set -euo pipefail

PROFILE="kyverno-demo"
NAMESPACE="kyverno-demo"
KYVERNO_NS="kyverno"
POLICY_REPORTER_NS="policy-reporter"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo ""
echo "================================================"
echo "  🛡️  Kyverno in Action — Teardown"
echo "================================================"
echo ""

read -rp "This will delete the Minikube cluster '$PROFILE'. Continue? (y/N) " answer
if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    info "Cancelled."
    exit 0
fi

# Remove Kyverno policies first so cleanup-controller and webhook stop interfering
info "Removing Kyverno policies..."
kubectl delete clusterpolicy --all 2>/dev/null || true
kubectl delete clustercleanuppolicy --all 2>/dev/null || true

# Delete demo namespaces
info "Deleting demo namespaces..."
kubectl delete namespace "$NAMESPACE" tenant-hawks --ignore-not-found --timeout=60s 2>/dev/null || true

# Uninstall Helm releases
info "Uninstalling Policy Reporter..."
helm uninstall policy-reporter -n "$POLICY_REPORTER_NS" 2>/dev/null || true
kubectl delete namespace "$POLICY_REPORTER_NS" --ignore-not-found 2>/dev/null || true

info "Uninstalling Kyverno..."
helm uninstall kyverno -n "$KYVERNO_NS" 2>/dev/null || true
kubectl delete namespace "$KYVERNO_NS" --ignore-not-found 2>/dev/null || true

# Kill any stale kubectl port-forwards from previous runs (the deploy
# script no longer starts one — it uses Docker's host-mapped port — but
# users who ran an older version may still have one lingering).
if pgrep -f "port-forward.*registry.*5000:80" >/dev/null; then
    info "Stopping a stale registry port-forward..."
    pkill -f "port-forward.*registry.*5000:80" 2>/dev/null || true
fi

# Delete Minikube profile
info "Deleting Minikube profile '$PROFILE'..."
minikube delete -p "$PROFILE"

echo ""
echo "================================================"
echo "  ✅ Teardown complete. System is clean."
echo ""
echo "  (Cosign keys in cosign/ are preserved.)"
echo "================================================"
