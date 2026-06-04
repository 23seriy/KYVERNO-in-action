#!/usr/bin/env bash
# Build images, push to the in-cluster registry, sign team-stats-api with
# Cosign, and deploy the compliant workload.
#
# Registry access on macOS + Docker Desktop is fiddly. Three constraints:
#
#   1. Port 5000 is hijacked by Apple's AirPlay Receiver, so we can't use
#      `localhost:5000` from the Mac at all. We use the Docker-mapped host
#      port that Minikube's Docker driver assigns (e.g. localhost:58206).
#   2. `docker push` cannot reach that port either — dockerd runs INSIDE
#      Docker Desktop's Linux VM, where `localhost` is the VM's loopback,
#      not the Mac's. Docker Desktop's host-port forwarder only handles
#      inbound from the Mac. So we don't use `docker push` at all.
#   3. Mac-side tools (curl, cosign, crane) reach the host-mapped port
#      directly with no issue.
#
# Path actually used:
#
#   docker save IMAGE → tarball                          (works: dockerd on Mac)
#   crane push tarball localhost:<port>/IMAGE            (works: crane on Mac)
#   cosign sign --allow-insecure-registry localhost:...  (works: cosign on Mac)
#   kubelet inside cluster pulls localhost:5000/IMAGE    (via registry-proxy)
#   kyverno inside cluster verifies signature            (same in-cluster path)
#
# Cosign keys live in `cosign/` at the repo root, gitignored.
set -euo pipefail

PROFILE="kyverno-demo"
NAMESPACE="kyverno-demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
COSIGN_DIR="$PROJECT_DIR/cosign"
IN_CLUSTER_REGISTRY="localhost:5000"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[FAIL]${NC} $*"; }

echo ""
echo "================================================"
echo "  🛡️  Kyverno in Action — Build, Sign, Deploy"
echo "================================================"
echo ""

# ── Tooling sanity check ─────────────────────────────────────────────────
for tool in docker crane cosign kubectl; do
    if ! command -v "$tool" &>/dev/null; then
        error "Required tool '$tool' is not installed. Run scripts/01-install-prerequisites.sh"
        exit 1
    fi
done

# ── Discover the Docker-mapped host port for the in-cluster registry ────
# Minikube's Docker driver maps the cluster's :5000 to a dynamic host port
# (e.g. 127.0.0.1:58206). Crane and Cosign reach it directly from the Mac.
HOST_REG_PORT=$(docker port "$PROFILE" 5000 2>/dev/null | head -1 | awk -F: '{print $NF}')
if [[ -z "$HOST_REG_PORT" ]]; then
    error "Could not discover the host-mapped registry port. Is the '$PROFILE' minikube cluster up?"
    error "Run: docker port $PROFILE 5000"
    exit 1
fi
HOST_REGISTRY="localhost:$HOST_REG_PORT"
info "Host registry (push/sign):  $HOST_REGISTRY"
info "In-cluster registry:        $IN_CLUSTER_REGISTRY  (kubelet + Kyverno)"

# Quick reachability check — fail fast if curl can't hit the registry
# from the Mac. Saves us from a long crane push timeout.
if ! curl -s --max-time 5 "http://$HOST_REGISTRY/v2/" >/dev/null; then
    error "Registry not reachable at http://$HOST_REGISTRY/v2/"
    error "Try: curl -v --max-time 5 http://$HOST_REGISTRY/v2/"
    error "And: kubectl get pods -n kube-system -l kubernetes.io/minikube-addons=registry"
    exit 1
fi
info "Registry reachable from Mac (verified with curl)"

# Sanity-check: kill any stale kubectl port-forwards from previous runs.
if pgrep -f "port-forward.*registry.*5000:80" >/dev/null; then
    warn "Stale kubectl port-forward on :5000 detected — killing it."
    pkill -f "port-forward.*registry.*5000:80" 2>/dev/null || true
fi

# ── Build images ─────────────────────────────────────────────────────────
# Tag with the host-port name (matches what crane will push to).
info "Building team-stats-api:v1..."
docker build -t "$HOST_REGISTRY/team-stats-api:v1" "$PROJECT_DIR/apps/team-stats-api"

info "Building trash-talk-bot:v1..."
docker build -t "$HOST_REGISTRY/trash-talk-bot:v1" "$PROJECT_DIR/apps/trash-talk-bot"

# Tag a :latest of trash-talk-bot — used by bad-pod 02-uses-latest-tag.
docker tag "$HOST_REGISTRY/trash-talk-bot:v1" "$HOST_REGISTRY/trash-talk-bot:latest"

# ── Push via crane (bypasses dockerd's VM-localhost dead-end) ───────────
# docker save spills the image to a tarball on the Mac, then crane pushes
# the tarball to the registry via plain HTTP — same Mac→registry network
# path that curl just used successfully.
TMPDIR_PUSH="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_PUSH"' EXIT

push_via_crane() {
    local image="$1"
    local safe_name
    safe_name=$(echo "$image" | tr '/:' '__')
    local tar="$TMPDIR_PUSH/${safe_name}.tar"

    info "  docker save → $(basename "$tar")"
    docker save -o "$tar" "$image"

    info "  crane push  → $image"
    crane push --insecure "$tar" "$image"
}

info "Pushing images to $HOST_REGISTRY via crane..."
push_via_crane "$HOST_REGISTRY/team-stats-api:v1"
push_via_crane "$HOST_REGISTRY/trash-talk-bot:v1"
push_via_crane "$HOST_REGISTRY/trash-talk-bot:latest"

# ── Cosign keypair ───────────────────────────────────────────────────────
mkdir -p "$COSIGN_DIR"
cd "$COSIGN_DIR"

if [[ ! -f cosign.key ]]; then
    info "Generating Cosign keypair (empty password, demo only)..."
    COSIGN_PASSWORD="" cosign generate-key-pair
else
    info "Re-using existing Cosign keypair in cosign/"
fi

# ── Cosign 3.x signing-config (no Rekor transparency log) ───────────────
# Cosign 3 removed the simple `--tlog-upload=false` flag in favour of an
# explicit signing-config file. We download the public Sigstore config
# and strip the rekorTlogUrls entries — exactly the recipe Cosign 3
# prints in its error message. Result: signing works fully offline once
# this file is on disk; nothing ever talks to Rekor.
SIGNING_CONFIG="signing-config.json"
if [[ ! -f "$SIGNING_CONFIG" ]]; then
    info "Fetching Sigstore signing-config and stripping rekorTlogUrls..."
    if ! curl -fsSL https://raw.githubusercontent.com/sigstore/root-signing/refs/heads/main/targets/signing_config.v0.2.json \
            | jq 'del(.rekorTlogUrls)' > "$SIGNING_CONFIG"; then
        rm -f "$SIGNING_CONFIG"
        error "Could not fetch Sigstore signing-config. Check network + 'jq' install."
        exit 1
    fi
fi

# ── Sign team-stats-api (NOT trash-talk-bot — that one stays unsigned) ──
# Signature is stored in the same OCI registry, keyed by digest, so it's
# discoverable from the in-cluster name too. --allow-insecure-registry is
# needed because Minikube's registry addon is HTTP, not HTTPS.
info "Signing team-stats-api:v1 with Cosign (at $HOST_REGISTRY)..."
COSIGN_PASSWORD="" cosign sign \
    --signing-config "$SIGNING_CONFIG" \
    --allow-insecure-registry \
    --key cosign.key \
    --yes \
    "$HOST_REGISTRY/team-stats-api:v1"

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
echo "  Host registry:        $HOST_REGISTRY  (push + sign)"
echo "  In-cluster registry:  $IN_CLUSTER_REGISTRY  (kubelet pull + Kyverno verify)"
echo "  Signed image:         team-stats-api:v1"
echo "  Unsigned image:       trash-talk-bot:{v1,latest}"
echo "  Cosign key:           $COSIGN_DIR/cosign.{key,pub}"
echo ""
echo "  Access the app:"
echo "    kubectl port-forward svc/team-stats-api 9080:8080 -n $NAMESPACE"
echo "    curl http://localhost:9080/teams"
echo ""
echo "  Next: ./scripts/04-demo-scenarios.sh"
echo "================================================"
