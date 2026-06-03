#!/usr/bin/env bash
# Start Minikube, enable the registry addon, install Kyverno + Policy Reporter.
set -euo pipefail

PROFILE="kyverno-demo"
K8S_VERSION="v1.32.0"
CPUS=4
MEMORY=6144
KYVERNO_NS="kyverno"
POLICY_REPORTER_NS="policy-reporter"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo ""
echo "================================================"
echo "  🛡️  Kyverno in Action — Cluster Setup"
echo "================================================"
echo ""

# Reuse or recreate profile
if minikube status -p "$PROFILE" &>/dev/null 2>&1; then
    warn "Minikube profile '$PROFILE' already exists."
    read -rp "Delete and recreate? (y/N) " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        info "Deleting existing profile..."
        minikube delete -p "$PROFILE"
    else
        info "Reusing existing profile."
        echo ""
        echo "  Next: ./scripts/03-deploy-app.sh"
        exit 0
    fi
fi

# Start Minikube
info "Starting Minikube (profile=$PROFILE, k8s=$K8S_VERSION, CPUs=$CPUS, RAM=${MEMORY}MB)..."
minikube start \
    -p "$PROFILE" \
    --kubernetes-version="$K8S_VERSION" \
    --cpus="$CPUS" \
    --memory="$MEMORY" \
    --driver=docker \
    --insecure-registry="10.0.0.0/24"

# Enable the registry addon so we can push signed images locally.
# Cosign needs images to live in an OCI registry (it stores signatures as
# separate OCI artefacts) — Minikube's `image load` shortcut isn't enough.
info "Enabling Minikube registry addon (localhost:5000)..."
minikube addons enable registry -p "$PROFILE"

# Add Helm repos
info "Adding Helm repositories..."
helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update
helm repo add policy-reporter https://kyverno.github.io/policy-reporter --force-update
helm repo update

# Helpers for surfacing what went wrong when a deploy gets stuck.
diagnose_namespace() {
    local ns=$1
    warn "Pods in $ns:"
    kubectl get pods -n "$ns" -o wide || true
    warn "Recent events in $ns (last 20):"
    kubectl get events -n "$ns" --sort-by=.lastTimestamp 2>/dev/null | tail -20 || true
    warn "Pull errors / Warning conditions in $ns:"
    kubectl describe pods -n "$ns" 2>/dev/null \
        | grep -E "Events:|Warning|Failed|ImagePull|ErrImage|OOMKilled" \
        | head -20 || true
    warn "If these are ImagePull errors, you're likely out of Docker disk."
    warn "  docker system df                          # check usage"
    warn "  minikube delete -p $PROFILE && \\"
    warn "    docker system prune -af && docker volume prune -af"
    warn "  ./scripts/02-start-cluster.sh             # retry"
}

# Install Kyverno (includes cleanup-controller and reports-controller).
# We don't pass --wait — image pulls on a fresh Minikube can take 5-10 min
# over a slow connection, and a single Helm timeout swallows the real cause.
# Instead, install async and follow with kubectl rollout status so failures
# surface deployment-by-deployment.
info "Installing Kyverno via Helm (async)..."
# --allowInsecureRegistries lets the admission + reports controllers reach
# Minikube's HTTP registry when verifying Cosign signatures (scenario 8).
# Without it, verifyImages can't fetch the signature blob over HTTP and
# every signed pod gets rejected.
helm upgrade --install kyverno kyverno/kyverno \
    --namespace "$KYVERNO_NS" \
    --create-namespace \
    --set admissionController.replicas=1 \
    --set backgroundController.replicas=1 \
    --set cleanupController.replicas=1 \
    --set reportsController.replicas=1 \
    --set 'admissionController.container.extraArgs.allowInsecureRegistries=true' \
    --set 'reportsController.container.extraArgs.allowInsecureRegistries=true'

info "Waiting for Kyverno controllers (up to 10 min — first run pulls ~800 MB)..."
if ! kubectl -n "$KYVERNO_NS" rollout status deploy --timeout=10m; then
    error "Kyverno controllers did not become ready in 10 min."
    diagnose_namespace "$KYVERNO_NS"
    exit 1
fi

# Sanity-check: confirm the flag is actually on the admission controller
# (Helm value path can drift between chart versions — fail loud if missing).
if ! kubectl -n "$KYVERNO_NS" get deploy kyverno-admission-controller -o yaml \
        | grep -q "allowInsecureRegistries"; then
    warn "Kyverno admission controller doesn't show --allowInsecureRegistries."
    warn "Cosign verifyImages (scenario 8) will fail against Minikube's HTTP registry."
    warn "If you see this, the chart value path may have changed — check 'helm show values kyverno/kyverno'."
fi

# Install Policy Reporter UI
info "Installing Policy Reporter UI (async)..."
helm upgrade --install policy-reporter policy-reporter/policy-reporter \
    --namespace "$POLICY_REPORTER_NS" \
    --create-namespace \
    --set ui.enabled=true \
    --set kyvernoPlugin.enabled=true

info "Waiting for Policy Reporter (up to 5 min)..."
if ! kubectl -n "$POLICY_REPORTER_NS" rollout status deploy --timeout=5m; then
    error "Policy Reporter did not become ready in 5 min."
    diagnose_namespace "$POLICY_REPORTER_NS"
    exit 1
fi

# Create the demo namespace up front
info "Creating namespace 'kyverno-demo'..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
kubectl apply -f "$PROJECT_DIR/k8s/namespace.yaml"

echo ""
info "Cluster + Kyverno status:"
kubectl get pods -n "$KYVERNO_NS"
echo ""
kubectl get pods -n "$POLICY_REPORTER_NS"
echo ""

echo "================================================"
echo "  ✅ Kyverno cluster ready!"
echo ""
echo "  Cluster:         $PROFILE"
echo "  K8s:             $K8S_VERSION"
echo "  Kyverno NS:      $KYVERNO_NS"
echo "  Registry addon:  enabled (localhost:5000)"
echo "  Policy Reporter: $POLICY_REPORTER_NS"
echo ""
echo "  Next: ./scripts/03-deploy-app.sh"
echo "================================================"
