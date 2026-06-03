#!/usr/bin/env bash
# Build images, push to the in-cluster registry, sign team-stats-api with
# Cosign, and deploy the compliant workload.
#
# Notes:
#   - The Minikube registry addon publishes on localhost:5000 of the host
#     via `kubectl port-forward`. We start a background port-forward,
#     push the images, then keep it running for the duration of the demo
#     (subsequent rebuilds reuse it).
#   - Cosign keys live in `cosign/` at the repo root, gitignored.
set -euo pipefail

PROFILE="kyverno-demo"
NAMESPACE="kyverno-demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
COSIGN_DIR="$PROJECT_DIR/cosign"
REGISTRY="localhost:5000"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo ""
echo "================================================"
echo "  🛡️  Kyverno in Action — Build, Sign, Deploy"
echo "================================================"
echo ""

# ── Port-forward the in-cluster registry to localhost:5000 ───────────────
if ! lsof -iTCP:5000 -sTCP:LISTEN -nP 2>/dev/null | grep -q kubectl; then
    info "Starting kubectl port-forward to the in-cluster registry..."
    kubectl port-forward --namespace kube-system service/registry 5000:80 >/dev/null 2>&1 &
    PF_PID=$!
    # Give it a moment to bind
    sleep 3
    if ! lsof -iTCP:5000 -sTCP:LISTEN -nP 2>/dev/null | grep -q "$PF_PID"; then
        warn "Port-forward did not bind cleanly. Retry: kubectl port-forward -n kube-system service/registry 5000:80"
    fi
else
    info "Registry port-forward already running on :5000"
fi

# ── Build images ─────────────────────────────────────────────────────────
info "Building team-stats-api:v1..."
docker build -t "$REGISTRY/team-stats-api:v1" "$PROJECT_DIR/apps/team-stats-api"

info "Building trash-talk-bot:v1..."
docker build -t "$REGISTRY/trash-talk-bot:v1" "$PROJECT_DIR/apps/trash-talk-bot"

# Also push a :latest tag of trash-talk-bot — used by bad-pod 02 to
# demonstrate the disallow-latest policy.
docker tag "$REGISTRY/trash-talk-bot:v1" "$REGISTRY/trash-talk-bot:latest"

# ── Push to in-cluster registry ─────────────────────────────────────────
info "Pushing images to $REGISTRY..."
docker push "$REGISTRY/team-stats-api:v1"
docker push "$REGISTRY/trash-talk-bot:v1"
docker push "$REGISTRY/trash-talk-bot:latest"

# ── Cosign keypair ───────────────────────────────────────────────────────
mkdir -p "$COSIGN_DIR"
cd "$COSIGN_DIR"

if [[ ! -f cosign.key ]]; then
    info "Generating Cosign keypair (empty password, demo only)..."
    COSIGN_PASSWORD="" cosign generate-key-pair
else
    info "Re-using existing Cosign keypair in cosign/"
fi

# ── Sign team-stats-api (NOT trash-talk-bot — that one stays unsigned) ──
info "Signing team-stats-api:v1 with Cosign..."
COSIGN_PASSWORD="" cosign sign \
    --tlog-upload=false \
    --key cosign.key \
    --yes \
    "$REGISTRY/team-stats-api:v1"

cd "$PROJECT_DIR"

# ── Embed the Cosign public key in the verify-image-signatures policy ──
info "Embedding Cosign public key into kyverno/08-verify-image-signatures.yaml..."
PUBLIC_KEY="$(cat "$COSIGN_DIR/cosign.pub")"
POLICY_FILE="$PROJECT_DIR/kyverno/08-verify-image-signatures.yaml"

# Replace the placeholder block with the real key. We use python because
# sed across multi-line PEM blocks is unreliable.
python3 - <<PY
import re, pathlib, textwrap

path = pathlib.Path("$POLICY_FILE")
src = path.read_text()
key = """$PUBLIC_KEY"""
# Indent every line of the PEM to match YAML (10 spaces).
indented = textwrap.indent(key.strip(), "                      ")
pattern = re.compile(
    r"publicKeys: \|-\n.*?-----END PUBLIC KEY-----",
    re.DOTALL,
)
replacement = f"publicKeys: |-\n{indented}"
new = pattern.sub(replacement, src)
path.write_text(new)
print("  policy file updated.")
PY

# ── Deploy the compliant workload ───────────────────────────────────────
info "Deploying team-stats-api (compliant tenant)..."
kubectl apply -f "$PROJECT_DIR/k8s/team-stats-api.yaml"

info "Waiting for team-stats-api to be ready..."
kubectl wait --for=condition=available deploy/team-stats-api -n "$NAMESPACE" --timeout=120s

echo ""
info "Pods in $NAMESPACE:"
kubectl get pods -n "$NAMESPACE" -o wide
echo ""

echo "================================================"
echo "  ✅ Build, sign, deploy complete!"
echo ""
echo "  Registry:        $REGISTRY (port-forwarded)"
echo "  Signed image:    $REGISTRY/team-stats-api:v1"
echo "  Unsigned image:  $REGISTRY/trash-talk-bot:{v1,latest}"
echo "  Cosign key:      $COSIGN_DIR/cosign.{key,pub}"
echo ""
echo "  Access the app:"
echo "    kubectl port-forward svc/team-stats-api 9080:8080 -n $NAMESPACE"
echo "    curl http://localhost:9080/teams"
echo ""
echo "  Next: ./scripts/04-demo-scenarios.sh"
echo "================================================"
