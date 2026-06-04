# 🛡️ Kyverno in Action

A hands-on project demonstrating **Kyverno** — policy-as-code admission control for Kubernetes. Built around an NBA scenario: the cluster is the arena, Kyverno is the front office, and your job is to stop rogue pods at the door instead of after they're already on the court.

The demo deploys one compliant tenant app (`team-stats-api`) and a "rogue" workload (`trash-talk-bot`) with seven manifest variants that each try to violate a different policy. You'll watch Kyverno reject them at admission time — and then watch the compliant app sail through.

![Kyverno](https://img.shields.io/badge/Kyverno-1.13+-FF6E33?logo=kubernetes&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-1.32-326CE5?logo=kubernetes&logoColor=white)
![Minikube](https://img.shields.io/badge/Minikube-local-F7B93E?logo=kubernetes&logoColor=white)
![Cosign](https://img.shields.io/badge/Cosign-signed-2EBB59?logo=sigstore&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white)

> 📝 **Read the full walkthrough on Medium:** _[Link coming soon]_

## 📖 Documentation

- **[CLAUDE.md](CLAUDE.md)** — Architecture, file structure, and common development tasks
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — How to contribute (features, fixes, docs)
- **[TESTING.md](TESTING.md)** — Manual and automated testing procedures
- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** — Common issues and solutions
- **[SECURITY.md](SECURITY.md)** — Security policies and responsible disclosure
- **[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)** — Community guidelines

## 🏗️ Architecture

```text
                ┌──────────────────────────────────────────────────────┐
                │                  Minikube Cluster                     │
                │                                                      │
                │   ┌──────────────────────────────────────────────┐   │
   kubectl ───► │   │      Kyverno Admission Webhook                │   │
   apply ...   │   │   (validate · mutate · generate · verifyImages)│   │
                │   └────────────────────┬────────────────────────┘   │
                │                        │                              │
                │     ✅ admitted         │      ❌ rejected             │
                │   ┌─────────────────┐  │    "image not signed"        │
                │   │ team-stats-api  │  │    "must runAsNonRoot"       │
                │   │ (signed, pinned,│  │    "missing team label"      │
                │   │  non-root, …)   │  │    "uses :latest"            │
                │   └─────────────────┘  │                              │
                │                        ▼                              │
                │             ┌────────────────────┐                    │
                │             │  trash-talk-bot    │  (one of seven     │
                │             │  (rogue variants)  │   bad-pod variants)│
                │             └────────────────────┘                    │
                │                                                      │
                │   tenant-hawks (label tenant=hawks)                   │
                │   └─► Kyverno generates: NetworkPolicy + Quota + LR   │
                │                                                      │
                │   📊 Policy Reporter UI  (kube-port-forward :8082)    │
                └──────────────────────────────────────────────────────┘
```

**team-stats-api** — Compliant tenant workload. Labeled, pinned tag, resource requests + limits, non-root, drop ALL caps, Cosign-signed. Passes every policy.

**trash-talk-bot** — The rogue workload. Used as the base image for seven bad-pod manifests, each violating one specific policy.

**tenant-hawks** — A new namespace labeled `tenant=hawks`. Demonstrates Kyverno's `generate` rule by materializing default-deny NetworkPolicy, ResourceQuota, and LimitRange automatically.

**Policy Reporter** — UI dashboard for cluster-wide policy violations.

## 📋 What You'll Learn

| Kyverno Feature | What It Does | Demo Scenario |
|---|---|---|
| **Validate** | Block bad resources at admission time | Required labels, no `:latest`, resources, PSS |
| **Mutate** | Auto-fix resources before they hit etcd | Inject default `env` label + `imagePullPolicy` |
| **Generate** | Create child resources from parents | New namespace → NetworkPolicy + Quota + LimitRange |
| **Verify Images** | Cosign signature enforcement | Block unsigned images at admission |
| **Cleanup Policy** | TTL-based deletion of matching resources | Auto-delete completed Job pods |
| **Background Scans** | Find pre-existing violations once a policy lands | `kubectl get policyreport -A` |
| **Policy Reports** | Cluster-wide violation visibility | Policy Reporter UI dashboard |

## 🚀 Quick Start

### Step 0: Clone the Repository

```bash
git clone https://github.com/23seriy/kyverno-in-action.git
cd kyverno-in-action
```

### Prerequisites

- **macOS** (scripts use Homebrew; adapt for Linux)
- **Docker Desktop** running
- ~6 GB RAM available for Minikube
- Python 3 on your `PATH` (used by `03-deploy-app.sh` to inject the Cosign public key)

### Step 1: Install Tools

```bash
chmod +x scripts/*.sh
./scripts/01-install-prerequisites.sh
```

Installs `minikube`, `kubectl`, `helm`, `kyverno` (CLI), `cosign`, `crane`, and `jq` via Homebrew. (`crane` is used to push images from the Mac directly, bypassing `dockerd`; `jq` is used to strip Rekor URLs from the Cosign 3.x signing-config — see Step 3 for the why on both.)

### Step 2: Start Cluster + Install Kyverno

```bash
./scripts/02-start-cluster.sh
```

Creates the `kyverno-demo` Minikube profile on **Kubernetes v1.32.0**, enables the **registry addon** (so Cosign-signed images have somewhere to live), installs Kyverno via Helm (admission + background + cleanup + reports controllers), and installs the Policy Reporter UI.

### Step 3: Build, Sign, and Deploy

```bash
./scripts/03-deploy-app.sh
```

- Discovers the Docker-mapped host port for the in-cluster registry
  (e.g. `localhost:58206`) and confirms it's reachable with `curl`
- Builds `team-stats-api:v1` and `trash-talk-bot:v1` with `docker build`
- **Pushes via `crane` instead of `docker push`** — see "macOS push path"
  below for why
- Generates a Cosign keypair in `cosign/` (gitignored)
- **Signs only `team-stats-api`** (`trash-talk-bot` stays unsigned on purpose)
- Patches `kyverno/08-verify-image-signatures.yaml` to embed the real public key
- Deploys `team-stats-api`

> **Two paths, one registry.** From your laptop, you reach the registry at
> `localhost:<host-mapped-port>`. From inside the cluster (kubelet pulls,
> Kyverno's `verifyImages`), it's `localhost:5000` via the in-cluster
> registry-proxy. Same OCI backend, same image digest, same signature blob —
> just two access paths. That's why the manifests and policies all
> reference `localhost:5000` even though pushes go elsewhere.

#### Why crane instead of `docker push` (macOS-specific)

On Docker Desktop, `dockerd` runs inside a Linux VM. When you do
`docker push localhost:58206/...`, dockerd resolves `localhost` to the
VM's own loopback — *not* the Mac's. Docker Desktop's host-port
forwarder only handles inbound from the Mac, so the push hangs with
`context deadline exceeded`.

`crane` is a single Go binary that pushes images via HTTP **directly from
the Mac**, using the same network path your browser and `curl` use. It
reads the image from your local Docker daemon (via `docker save`) and
streams it to the registry — no dockerd network involvement on the push
side. Same trick works for `cosign sign`, which already runs on the Mac
and just needs `--allow-insecure-registry` to talk to Minikube's HTTP
registry.

### Step 4: Reach the Compliant App

```bash
kubectl port-forward svc/team-stats-api 9080:8080 -n kyverno-demo
```

```bash
curl http://localhost:9080/teams
curl http://localhost:9080/standings/East
curl http://localhost:9080/health
```

### Step 5: Run the Demo Scenarios

```bash
./scripts/04-demo-scenarios.sh
```

Eleven interactive scenarios, one policy at a time.

## 🎮 Demo Scenarios

### 1. Baseline — The Arena Has No Bouncers

No policies. Every bad pod is admitted. This is the world before Kyverno.

### 2. Require Labels — Team Jerseys at the Door

```bash
kubectl apply -f kyverno/01-require-labels.yaml
kubectl apply -f k8s/bad-pods/03-missing-labels.yaml   # REJECTED
```

Every pod must declare `team` and `env` labels.

### 3. No `:latest` — No Undrafted Players

```bash
kubectl apply -f kyverno/02-disallow-latest-tag.yaml
kubectl apply -f k8s/bad-pods/02-uses-latest-tag.yaml  # REJECTED
```

Bare images and `:latest` tags are forbidden; rollbacks need a real version.

### 4. Require Resources — No Unlimited Minutes

```bash
kubectl apply -f kyverno/03-require-resources.yaml
kubectl apply -f k8s/bad-pods/04-no-resources.yaml     # REJECTED
```

Every container must declare CPU + memory requests **and** limits.

### 5. Pod Security Restricted — Locker Room Rules

```bash
kubectl apply -f kyverno/04-pod-security-restricted.yaml
kubectl apply -f k8s/bad-pods/01-runs-as-root.yaml     # REJECTED
kubectl apply -f k8s/bad-pods/05-host-path.yaml        # REJECTED
kubectl apply -f k8s/bad-pods/06-privileged.yaml       # REJECTED
```

Enforces the PSS "restricted" profile: no privileged, no hostPath, runAsNonRoot, drop ALL caps, no privilege escalation.

### 6. Mutate — The Coach Adjusts

```bash
kubectl apply -f kyverno/05-mutate-default-pull-policy.yaml
kubectl apply -f kyverno/06-mutate-add-default-labels.yaml
```

Apply a pod missing `env` and `imagePullPolicy` — Kyverno injects both before the pod is stored. Tenants stop arguing about ergonomics.

### 7. Generate — New Franchise Setup

```bash
kubectl apply -f kyverno/07-generate-tenant-defaults.yaml
kubectl apply -f k8s/tenant-namespace.yaml
kubectl get networkpolicy,resourcequota,limitrange -n tenant-hawks
```

Create a namespace with `tenant=hawks`. Kyverno auto-generates a default-deny `NetworkPolicy`, a `ResourceQuota`, and a `LimitRange` — and reconciles them if tenants edit them.

### 8. Verify Image Signatures — Player ID Check

```bash
kubectl apply -f kyverno/08-verify-image-signatures.yaml
kubectl apply -f k8s/team-stats-api.yaml               # ADMITTED  (signed)
kubectl apply -f k8s/bad-pods/07-unsigned-image.yaml   # REJECTED  (unsigned)
```

Kyverno's `verifyImages` rule intercepts admission, fetches the OCI signature artefact, and verifies it against the public key inlined in the policy. Unsigned images can't run.

### 9. Cleanup — End-of-Game Locker Clear-Out

```bash
kubectl apply -f kyverno/09-cleanup-old-pods.yaml
```

Every minute, the cleanup-controller deletes pods in `Succeeded` or `Failed` phase in `kyverno-demo` or `tenant-*`. Run a Job, watch it disappear within ~60 seconds.

### 10. Policy Reports — The Referee's Report

```bash
kubectl get policyreport -A
kubectl port-forward -n policy-reporter svc/policy-reporter-ui 8082:8080
# open http://localhost:8082
```

Background scans surface pre-existing violations. The Policy Reporter UI turns YAML into something auditors actually read.

### 11. Full Baseline — Production-Ready Hardened State

```bash
kubectl apply -f kyverno/10-full-baseline.yaml
kubectl apply -f kyverno/07-generate-tenant-defaults.yaml
kubectl apply -f kyverno/08-verify-image-signatures.yaml
kubectl apply -f kyverno/09-cleanup-old-pods.yaml
```

The end state: every rogue pod is rejected by something; the compliant tenant app passes every rule.

## 🔧 Useful Commands

```bash
# Active policies (cluster scope)
kubectl get clusterpolicy
kubectl get clustercleanuppolicy

# Per-resource report
kubectl get policyreport -n kyverno-demo
kubectl describe policyreport <name> -n kyverno-demo

# Cluster-wide failing rules
kubectl get policyreport -A -o json | \
    jq '.items[].results[] | select(.result=="fail") | {policy, rule, message}'

# Inspect Kyverno itself
kubectl get pods -n kyverno
kubectl logs -n kyverno deploy/kyverno-admission-controller -f

# Test a policy without applying it (handy for CI)
kyverno apply kyverno/04-pod-security-restricted.yaml --resource k8s/bad-pods/01-runs-as-root.yaml

# Verify a Cosign signature directly
cosign verify --key cosign/cosign.pub --insecure-ignore-tlog \
    localhost:5000/team-stats-api:v1
```

## 📁 Project Structure

```text
kyverno-in-action/
├── apps/
│   ├── team-stats-api/         # Compliant Flask app (non-root, multi-stage)
│   │   ├── app.py              # NBA team standings + per-team detail
│   │   ├── Dockerfile          # Multi-stage, runs as UID 10001
│   │   └── requirements.txt
│   └── trash-talk-bot/         # Rogue base image, reused by bad-pod variants
│       ├── app.py
│       ├── Dockerfile
│       └── requirements.txt
├── k8s/
│   ├── namespace.yaml          # kyverno-demo
│   ├── team-stats-api.yaml     # Compliant Deployment + Service
│   ├── tenant-namespace.yaml   # tenant-hawks — triggers the Generate policy
│   └── bad-pods/
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
│   ├── 07-generate-tenant-defaults.yaml      # Generate NP + Quota + LimitRange
│   ├── 08-verify-image-signatures.yaml       # Cosign verifyImages
│   ├── 09-cleanup-old-pods.yaml              # ClusterCleanupPolicy
│   └── 10-full-baseline.yaml                 # Composite production policy
├── scripts/
│   ├── 01-install-prerequisites.sh
│   ├── 02-start-cluster.sh
│   ├── 03-deploy-app.sh
│   ├── 04-demo-scenarios.sh
│   └── 05-teardown.sh
├── docs/
│   └── medium-story.md         # Full Medium article
├── README.md
├── LICENSE
└── .gitignore
```

## 🧹 Teardown

```bash
./scripts/05-teardown.sh
```

Deletes all policies, uninstalls Kyverno + Policy Reporter, removes the Minikube cluster, and stops the registry port-forward. Cosign keys in `cosign/` are preserved so you can re-sign without re-generating.

## 💡 Key Takeaways

1. **Admission control is the gatekeeper.** A pod that never gets admitted can't cause an incident. Fix at the door, not in post-mortems.

2. **Mutate prevents toil.** Instead of telling teams "you forgot the env label", inject a sane default and let them keep moving.

3. **Generate enables self-service.** A new namespace lands with a default-deny NetworkPolicy, a quota, and a LimitRange — without a ticket.

4. **Image verification closes the supply-chain gap.** Cosign signatures, verified by Kyverno's `verifyImages` rule, give you cryptographic assurance that only trusted images ran on the cluster.

5. **Background scans surface pre-existing violations.** When a new policy lands, Kyverno scans existing resources too — so you discover the broken stuff before audit day, not during it.

6. **Policy Reports turn YAML into something auditors read.** SOC2 evidence becomes a `kubectl` query instead of a screenshot hunt.

7. **It's just YAML.** Kyverno is Helm-installable, version-controlled, GitOps-ready, and reuses `kubectl` instead of teaching you a new DSL like Rego.

## 📚 Resources

- [Kyverno Documentation](https://kyverno.io/docs/)
- [Kyverno Policy Library](https://kyverno.io/policies/)
- [Kyverno verifyImages reference](https://kyverno.io/docs/policy-types/cluster-policy/verify-images/)
- [Cosign Documentation](https://docs.sigstore.dev/cosign/overview/)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Policy Reporter](https://kyverno.github.io/policy-reporter/)
- [Minikube Documentation](https://minikube.sigs.k8s.io/docs/)

## 📝 License

MIT — Use freely for learning, demos, and presentations.
