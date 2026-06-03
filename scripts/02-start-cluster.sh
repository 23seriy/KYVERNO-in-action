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

# Install Kyverno (includes cleanup-controller and reports-controller)
info "Installing Kyverno via Helm..."
helm upgrade --install kyverno kyverno/kyverno \
    --namespace "$KYVERNO_NS" \
    --create-namespace \
    --set admissionController.replicas=1 \
    --set backgroundController.replicas=1 \
    --set cleanupController.replicas=1 \
    --set reportsController.replicas=1 \
    --wait --timeout=5m

info "Waiting for Kyverno controllers to be ready..."
kubectl -n "$KYVERNO_NS" rollout status deploy --timeout=180s

# Install Policy Reporter UI
info "Installing Policy Reporter UI..."
helm upgrade --install policy-reporter policy-reporter/policy-reporter \
    --namespace "$POLICY_REPORTER_NS" \
    --create-namespace \
    --set ui.enabled=true \
    --set kyvernoPlugin.enabled=true \
    --wait --timeout=5m

info "Waiting for Policy Reporter to be ready..."
kubectl -n "$POLICY_REPORTER_NS" rollout status deploy --timeout=180s

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
