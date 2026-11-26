#!/usr/bin/env bash
# Install prerequisites for Kyverno in Action.
# Installs: minikube, kubectl, helm, kyverno CLI, cosign
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

install_if_missing() {
    local tool=$1
    local formula=${2:-$1}
    if command -v "$tool" &>/dev/null; then
        info "$tool already installed: $(command -v "$tool")"
    else
        info "Installing $tool via Homebrew (formula: $formula)..."
        brew install "$formula"
    fi
}

echo ""
echo "================================================"
echo "  🛡️  Kyverno in Action — Prerequisites Installer"
echo "================================================"
echo ""

# Check Homebrew
if ! command -v brew &>/dev/null; then
    echo "❌ Homebrew is required. Install from https://brew.sh"
    exit 1
fi
info "Homebrew found"

# Install tools first. Don't gate this on Docker — a fresh Mac has no Docker,
# and aborting here left minikube/helm uninstalled with a confusing exit.
install_if_missing minikube
install_if_missing kubectl
install_if_missing helm
install_if_missing kyverno
install_if_missing cosign
# crane is used to push images to the in-cluster registry from the Mac
# directly, bypassing dockerd (whose localhost is its own VM, not the Mac).
install_if_missing crane
# jq is used by 03-deploy-app.sh to strip Rekor URLs from the Sigstore
# signing-config (Cosign 3.x replaces --tlog-upload=false).
install_if_missing jq

# Docker Desktop is the Minikube driver. Check it last and warn (not exit)
# so this script always leaves the CLI tools in place.
docker_ok=true
if ! command -v docker &>/dev/null; then
    warn "Docker Desktop is not installed — Minikube's docker driver needs it."
    warn "Install it from https://www.docker.com/products/docker-desktop/ (or: brew install --cask docker)"
    docker_ok=false
elif ! docker info &>/dev/null 2>&1; then
    # Match Minikube's own failure exactly: it connects over this socket.
    if [[ ! -S /var/run/docker.sock ]]; then
        warn "Docker is installed but the daemon is not running (no /var/run/docker.sock)."
    else
        warn "Docker is installed but 'docker info' failed. Try restarting Docker Desktop."
    fi
    warn "Start Docker Desktop (open -a Docker) and wait for it to finish booting."
    docker_ok=false
fi

echo ""
echo "================================================"
if [[ "$docker_ok" == true ]]; then
    echo "  ✅ All prerequisites installed!"
    echo ""
    echo "  Next: ./scripts/02-start-cluster.sh"
else
    echo "  ⚠️  CLI tools installed, but Docker needs attention."
    echo ""
    echo "  1. Install/start Docker Desktop and confirm: docker info"
    echo "  2. Then run: ./scripts/02-start-cluster.sh"
fi
echo "================================================"
