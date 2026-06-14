# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**kyverno-in-action** is a hands-on portfolio project demonstrating Kyverno — a policy-as-code admission controller for Kubernetes. The demo uses an NBA arena metaphor: the cluster is the arena, Kyverno is the admission control at the door, and the goal is to stop rogue pods before they run.

The project consists of:
- **Two sample apps** (team-stats-api: compliant; trash-talk-bot: non-compliant base image)
- **Seven bad-pod variants** each violating one specific security policy
- **Ten Kyverno policies** covering validate, mutate, generate, image verification, and cleanup
- **Five orchestration scripts** that set up the cluster and run 11 interactive demo scenarios

## Architecture & Key Concepts

### Policy Enforcement Flow

When `kubectl apply` sends a manifest, it hits Kyverno's admission webhook:

1. **Validate rules** block manifests that violate policies (e.g., missing labels, `:latest` tag, no resource requests, runs as root, unsigned images)
2. **Mutate rules** auto-inject fields before storage (e.g., add default `env` label, set `imagePullPolicy: IfNotPresent`)
3. **Generate rules** create child resources when a parent lands (e.g., namespace with `tenant=hawks` auto-creates default-deny NetworkPolicy, ResourceQuota, LimitRange)
4. **Verify rules** check Cosign signatures against a hardcoded public key
5. **Cleanup policies** periodically delete matching resources on a schedule (e.g., completed pods)

### Cosign Signing & Registry Path Duality

- **On the Mac** (your laptop): images are pushed to `localhost:<host-port>` via `crane` (a direct HTTP client)
- **Inside the cluster**: the same images are accessed via `localhost:5000` (Minikube's registry proxy)
- Both resolve to the same OCI backend and same image digest — just two network paths

`crane` is used instead of `docker push` because Docker Desktop's `dockerd` runs in a Linux VM; `docker push localhost:5000/...` resolves `localhost` to the VM's loopback, not the Mac's. `crane` streams directly from the Mac, bypassing dockerd's network.

### Demo Scenario Sequence

1. **Baseline** — No policies; all bad pods admitted
2. **Require Labels** — Reject missing `team` and `env` labels
3. **No :latest** — Reject bare or `:latest` image tags
4. **Require Resources** — Reject missing CPU/memory requests or limits
5. **Pod Security Restricted** — Enforce PSS "restricted" profile (no root, no privileged, no hostPath, drop ALL caps)
6. **Mutate** — Auto-inject `env` label and `imagePullPolicy`
7. **Generate** — Auto-create NetworkPolicy + Quota + LimitRange in new tenant namespaces
8. **Verify Image Signatures** — Block unsigned images via Cosign verification
9. **Cleanup** — Auto-delete completed pods on a schedule
10. **Policy Reports** — Background scans surface pre-existing violations
11. **Full Baseline** — All policies active; compliant app passes everything; bad pods rejected

Each scenario is self-contained and can be run independently. The script cleans up policies from the previous scenario before starting the next one.

## File Structure

```
kyverno-in-action/
├── apps/
│   ├── team-stats-api/        # Compliant Flask app (Dockerfile: multi-stage, non-root UID 10001)
│   └── trash-talk-bot/        # Base image for bad-pod manifests
├── k8s/
│   ├── namespace.yaml         # kyverno-demo namespace
│   ├── team-stats-api.yaml    # Compliant Deployment + Service
│   ├── tenant-namespace.yaml  # tenant-hawks (triggers Generate policy)
│   └── bad-pods/              # Seven variants, each violating one policy
│       ├── 01-runs-as-root.yaml
│       ├── 02-uses-latest-tag.yaml
│       ├── 03-missing-labels.yaml
│       ├── 04-no-resources.yaml
│       ├── 05-host-path.yaml
│       ├── 06-privileged.yaml
│       └── 07-unsigned-image.yaml
├── kyverno/
│   ├── 01-require-labels.yaml
│   ├── 02-disallow-latest-tag.yaml
│   ├── 03-require-resources.yaml
│   ├── 04-pod-security-restricted.yaml
│   ├── 05-mutate-default-pull-policy.yaml
│   ├── 06-mutate-add-default-labels.yaml
│   ├── 07-generate-tenant-defaults.yaml
│   ├── 08-verify-image-signatures.yaml    # Patched by 03-deploy-app.sh with real public key
│   ├── 09-cleanup-old-pods.yaml
│   └── 10-full-baseline.yaml
├── scripts/
│   ├── 01-install-prerequisites.sh        # Homebrew: minikube, kubectl, helm, kyverno, cosign, crane, jq
│   ├── 02-start-cluster.sh                # Create Minikube profile, enable registry, install Kyverno + Policy Reporter
│   ├── 03-deploy-app.sh                   # Build images, sign with Cosign, patch policy, deploy app
│   ├── 04-demo-scenarios.sh               # 11 interactive scenarios with press-ENTER pauses
│   └── 05-teardown.sh                     # Clean policies, uninstall controllers, delete cluster
├── cosign/                                 # Cosign public/private keys (gitignored)
├── docs/
│   └── medium-story.md
└── README.md
```

## Common Tasks

### Run the Full Demo

```bash
chmod +x scripts/*.sh
./scripts/01-install-prerequisites.sh      # Install tools via Homebrew
./scripts/02-start-cluster.sh               # Create Minikube + install Kyverno
./scripts/03-deploy-app.sh                  # Build, sign, deploy apps
./scripts/04-demo-scenarios.sh              # Run 11 interactive scenarios
./scripts/05-teardown.sh                    # Delete cluster + policies
```

### Test a Single Policy

```bash
kyverno apply kyverno/04-pod-security-restricted.yaml --resource k8s/bad-pods/01-runs-as-root.yaml
```

### Inspect Policies & Violations

```bash
kubectl get clusterpolicy                           # List active policies
kubectl get clustercleanuppolicy                    # List cleanup policies
kubectl get policyreport -A                         # Cluster-wide violation reports
kubectl describe policyreport <name> -n kyverno-demo
```

### Verify a Cosign Signature Manually

```bash
cosign verify --key cosign/cosign.pub --insecure-ignore-tlog \
    localhost:5000/team-stats-api:v1
```

### Debug Kyverno Admission

```bash
kubectl logs -n kyverno deploy/kyverno-admission-controller -f
```

### Port-Forward to Compliant App

```bash
kubectl port-forward svc/team-stats-api 9080:8080 -n kyverno-demo
curl http://localhost:9080/teams
```

### Port-Forward to Policy Reporter UI

```bash
kubectl port-forward -n policy-reporter svc/policy-reporter-ui 8082:8080
open http://localhost:8082
```

## Script Internals

All scripts use `set -euo pipefail` for strict error handling. They define helper functions (`info()`, `warn()`) and use color-coded output. Expect interactive prompts (e.g., "Delete and recreate?" in `02-start-cluster.sh`).

### 03-deploy-app.sh: Key Steps

1. Discovers the registry host-port from Minikube's registry addon
2. Builds both apps with `docker build`
3. Pushes both images using `crane` (not `docker push`)
4. Generates a fresh Cosign keypair in `cosign/` (gitignored)
5. Signs **only** `team-stats-api:v1` (trash-talk-bot stays unsigned)
6. Extracts the Cosign public key and patches `kyverno/08-verify-image-signatures.yaml` with it (via Python)
7. Applies `k8s/namespace.yaml` and `k8s/team-stats-api.yaml`

### 04-demo-scenarios.sh: Scenario Pattern

Each scenario:
1. Cleans up policies from the previous scenario
2. Deletes any bad pods left behind
3. Applies the scenario's policy (or policies)
4. Applies test manifests and shows results (✅ Admitted or ✅ Rejected)
5. Pauses for `Press ENTER to continue`

The script is idempotent — running it twice in a row is safe; the second run will delete and recreate the same policies.

## Development Notes

### Adding a New Policy

1. Create `kyverno/NN-<policy-name>.yaml` with a `ClusterPolicy` manifest
2. Add a new scenario section to `04-demo-scenarios.sh` that applies the policy and tests it against relevant bad-pods
3. If the policy should appear in the "Full Baseline" (scenario 11), add it to `10-full-baseline.yaml`

### Adding a New Bad-Pod Variant

1. Create `k8s/bad-pods/NN-<violation>.yaml` (Pod or Deployment)
2. Reference it in the appropriate scenario in `04-demo-scenarios.sh`
3. Use the `trash-talk-bot` image so all variants share the same base

### Modifying Apps

Both `team-stats-api` and `trash-talk-bot` are Flask apps. The Dockerfile uses a multi-stage build pattern:
- **Stage 1**: Install Python deps into `/install`
- **Stage 2**: Copy installed deps, add non-root user (UID 10001), run as that user

The compliant app (`team-stats-api`) is intentionally simple — it serves NBA standings data. Its purpose is to demonstrate a pod that passes all policies, not to be feature-rich.

### Cosign Workflow

- `03-deploy-app.sh` generates a keypair if `cosign/cosign.key` and `cosign/cosign.pub` don't exist
- Keys are gitignored so they don't leak
- Only `team-stats-api` is signed to demonstrate the difference between signed and unsigned images in the verification scenario
- The public key is extracted and inlined into `kyverno/08-verify-image-signatures.yaml`

## Kyverno Concepts Used

| Feature | Kyverno Rule Type | Example Scenario |
|---------|-------------------|------------------|
| Block bad manifests | `validation` | Scenario 2–5: reject missing labels, `:latest`, no resources, root/privileged |
| Auto-fix manifests | `mutation` | Scenario 6: inject `env` label and `imagePullPolicy` |
| Auto-create resources | `generation` | Scenario 7: create NetworkPolicy + Quota + LimitRange in new namespaces |
| Verify signatures | `image verification` | Scenario 8: Cosign signature check |
| TTL-based deletion | `ClusterCleanupPolicy` | Scenario 9: delete completed pods on a schedule |
| Find violations | Background scans | Scenario 10: `kubectl get policyreport -A` |

Kyverno is Helm-installable, uses only YAML, and is GitOps-ready — no DSLs like Rego required.

## Testing & Validation

Run `04-demo-scenarios.sh` to validate the entire flow. Each scenario is a self-contained test: if a policy is correctly written, the compliant manifests are admitted and the bad manifests are rejected. The script checks for the expected outcomes and reports pass/fail.

To test policies in isolation without running the full demo:

```bash
kyverno apply kyverno/<policy-file>.yaml --resource k8s/<test-manifest>.yaml
```

This prints the policy decision (pass/fail) without creating any cluster resources.
