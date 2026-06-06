# Kyverno in Action: Policy-as-Code Admission Control for Kubernetes — From Free-for-All to Production Baseline on Your Laptop

_A hands-on guide to validate, mutate, generate, verify, and clean up — without learning Rego, without sidecars, and entirely on Minikube._

---

## Your Cluster Is a Wide-Open Arena

Here's the uncomfortable truth about most Kubernetes clusters I've seen: **anyone with `kubectl apply` access can ship just about anything.**

A new engineer's pod mounts `/var/run/docker.sock`, runs as root, pulls `:latest` from a random registry, and skips resource limits entirely. It deploys fine. Nobody notices for three weeks. By the time someone finds it, it's "prod-ish." A noisy neighbour starts evicting other pods. A compliance auditor asks for a list of every workload that runs as root, and you spend an afternoon writing a `jq` query.

You can fix this once the pod is running. But that's the wrong layer. The fix belongs at the **door** — before the YAML hits etcd.

That door is the **admission controller**. And the most pragmatic admission controller in the Kubernetes ecosystem right now is **Kyverno**.

In this article, we'll build a complete Kyverno demo on Minikube. We'll start with an open cluster, layer on one policy at a time, and end with a hardened production baseline that includes Cosign image signature verification, automated tenant onboarding, and TTL-based cleanup. Every step runs on your laptop.

> **Full source code:** [github.com/23seriy/kyverno-in-action](https://github.com/23seriy/kyverno-in-action)

---

## What We're Building

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
                │   │ (signed, pinned)│  │    "missing team label"      │
                │   └─────────────────┘  │    "uses :latest"            │
                │                        ▼                              │
                │             ┌────────────────────┐                    │
                │             │  trash-talk-bot    │  (rogue variants)  │
                │             └────────────────────┘                    │
                └──────────────────────────────────────────────────────┘
```

Two workloads, NBA-themed:

- **`team-stats-api`** — the compliant tenant app. A small Flask service that returns NBA team standings. It's deliberately squeaky-clean: pinned image tag, resource requests + limits, runs as a non-root user, drops every Linux capability, and ships with a Cosign signature.
- **`trash-talk-bot`** — the rogue workload. We'll deploy it in seven different shapes, each violating exactly one Kyverno policy: runs as root, uses `:latest`, missing labels, no resources, hostPath, privileged, and unsigned image. Each one should get **rejected at admission**, not after it's running.

And we'll demo all five of Kyverno's superpowers:

| Feature | What it does |
|---|---|
| **Validate** | Block resources that don't match a pattern |
| **Mutate** | Inject defaults / fix resources before they're stored |
| **Generate** | Create child resources when a parent appears |
| **Verify Images** | Cosign signature enforcement |
| **Cleanup** | TTL-based deletion of matching resources |

---

## Why Kyverno (and not OPA/Gatekeeper)

If you've shopped for an admission controller before, you've probably seen the OPA/Gatekeeper option. Both work. Here's the honest comparison:

| | **Kyverno** | **OPA/Gatekeeper** |
|---|---|---|
| Policy language | YAML (Kubernetes-native) | Rego (custom DSL) |
| Mutate | ✅ First-class | ⚠️ Separate Gatekeeper component, less mature |
| Generate | ✅ First-class | ❌ Not supported |
| Cleanup | ✅ Built-in cleanup-controller | ❌ Separate tool |
| Image verification (Cosign) | ✅ `verifyImages` rule | ⚠️ External, more wiring |
| Learning curve | Low — looks like K8s manifests | Steep — Rego is a new language |
| Policy library | ~300 curated policies | Smaller, more DIY |

**Kyverno is the right default for most teams** because it stays inside the YAML mental model your team already has, and it covers the four big use cases — validate, mutate, generate, verifyImages — in one operator. OPA still wins for cross-cutting policy that needs to query external data or run outside Kubernetes (think: Terraform plans, CI gates, multi-platform policy).

For a portfolio-grade Kubernetes security story, Kyverno is the easier sell.

---

## Prerequisites

- **Docker Desktop** running
- **Homebrew** (macOS) — the install script handles everything else
- ~6 GB free RAM for Minikube
- **Python 3** on `$PATH` — used by the deploy script to inject the Cosign public key into the policy

```bash
git clone https://github.com/23seriy/kyverno-in-action.git
cd kyverno-in-action
./scripts/01-install-prerequisites.sh
```

That installs `minikube`, `kubectl`, `helm`, the `kyverno` CLI, and `cosign`.

---

## Step 1: Start the Cluster and Install Kyverno

```bash
./scripts/02-start-cluster.sh
```

A few things happen here that are worth pointing out:

1. **The Minikube registry addon is enabled.** Cosign stores signatures as separate OCI artefacts in an image registry — so signing only works if your images live in one. `minikube image load` won't cut it. The registry addon publishes a registry inside the cluster at `localhost:5000` (via a `kubectl port-forward` we'll start next).

2. **Kyverno is installed via Helm with all four controllers.** Modern Kyverno (1.10+) splits responsibility across:
   - **admission-controller** — the webhook that intercepts API requests
   - **background-controller** — re-scans existing resources when a new policy lands
   - **cleanup-controller** — runs the TTL cleanup policies
   - **reports-controller** — produces the `PolicyReport` objects

3. **Policy Reporter UI is installed.** The CLI `kubectl get policyreport` is fine for engineers, but the UI is what you screenshot for the audit binder.

Verify everything is up:

```bash
kubectl get pods -n kyverno
kubectl get pods -n policy-reporter
```

---

## Step 2: Build, Sign, Deploy

```bash
./scripts/03-deploy-app.sh
```

This does five things in sequence:

1. **Port-forwards the in-cluster registry** to `localhost:5000` on your laptop.
2. **Builds both Docker images** (`team-stats-api:v1` and `trash-talk-bot:v1` and `:latest`) and pushes them to that registry.
3. **Generates a Cosign keypair** in `cosign/` (gitignored).
4. **Signs `team-stats-api:v1`** with Cosign. The signature is stored as a sibling OCI artefact in the same registry. `trash-talk-bot` is deliberately left unsigned.
5. **Patches the policy file** `kyverno/08-verify-image-signatures.yaml` to embed the real public key instead of the placeholder.

After this, `cosign verify` confirms the signature directly:

```bash
cosign verify --key cosign/cosign.pub --insecure-ignore-tlog \
    localhost:5000/team-stats-api:v1
```

---

## Scenario 1: Baseline — The Arena Has No Bouncers

No Kyverno policies are active yet. Every bad pod is admitted:

```bash
kubectl apply -f k8s/bad-pods/01-runs-as-root.yaml      # admitted
kubectl apply -f k8s/bad-pods/03-missing-labels.yaml    # admitted
kubectl apply -f k8s/bad-pods/02-uses-latest-tag.yaml   # admitted
```

This is the default world. It's also the world most clusters start out in, because admission control is opt-in.

---

## Scenario 2: Validate — Team Jerseys at the Door

First, clean up any bad pods from Scenario 1:

```bash
kubectl delete pods -n kyverno-demo trash-talk-root trash-talk-no-labels trash-talk-latest --ignore-not-found
```

Our first policy. Every pod in `kyverno-demo` must declare a `team` and an `env` label:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-and-env-labels
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: require-labels
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [kyverno-demo, "tenant-*"]
      validate:
        message: "Pods must include `team` and `env` labels."
        pattern:
          metadata:
            labels:
              team: "?*"
              env: "?*"
```

A few details about this YAML are worth slowing down on:

- `validationFailureAction: Enforce` — reject violators at admission. The alternative is `Audit`, which records violations in PolicyReports but doesn't block.
- `background: true` — also scan **existing** pods when this policy is created. If a pod was admitted before the policy existed, you still get visibility on the violation.
- `pattern: ... "?*"` — Kyverno's pattern syntax. `"?*"` means "any non-empty string." Combined with the `metadata.labels` object pattern, this enforces the presence of both keys.

Now apply the policy first, then try the rogue pod with no labels:

```bash
kubectl apply -f kyverno/01-require-labels.yaml
kubectl apply -f k8s/bad-pods/03-missing-labels.yaml
# Error from server: admission webhook "validate.kyverno.svc-fail" denied
# the request: resource Pod/.../trash-talk-no-labels was blocked due to
# the following policies require-team-and-env-labels: require-labels:
# 'Pods must include `team` and `env` labels.'
```

That's the experience we want — a clear, actionable error at `kubectl apply` time. Not a runtime surprise.

---

## Scenario 3: No `:latest` — No Undrafted Players

Clean up from Scenario 2:

```bash
kubectl delete clusterpolicy require-team-and-env-labels
kubectl delete pods -n kyverno-demo trash-talk-no-labels --ignore-not-found
```

`:latest` is the most common foot-gun in Kubernetes. It silently breaks rollbacks, it's invisible in git history, and it makes incident forensics miserable.

```yaml
- name: forbid-latest
  validate:
    message: "Image tag `:latest` is forbidden. Pin to a real version."
    pattern:
      spec:
        containers:
          - name: "*"
            image: "!*:latest"
```

The `!*:latest` is the negation pattern: "anything **except** a string ending in `:latest`." There's a sibling rule that requires an explicit tag (`*:*`), so bare image references (which K8s implicitly turns into `:latest`) are also rejected.

Apply the policy and test:

```bash
kubectl apply -f kyverno/02-disallow-latest-tag.yaml
kubectl apply -f k8s/bad-pods/02-uses-latest-tag.yaml
# Error from server: admission webhook "validate.kyverno.svc-fail" denied
# the request: resource Pod/.../trash-talk-latest was blocked due to
# the following policies disallow-latest-tag: forbid-latest:
# 'Image tag `:latest` is forbidden. Pin to a real version.'
```

---

## Scenario 4: Pod Security — Locker Room Rules

Clean up from Scenario 3:

```bash
kubectl delete clusterpolicy disallow-latest-tag
kubectl delete pods -n kyverno-demo trash-talk-latest --ignore-not-found
```

Now the big one: the Pod Security Standards "restricted" profile.

Kubernetes ships a built-in [PodSecurity admission plugin](https://kubernetes.io/docs/concepts/security/pod-security-admission/) that does this same job. So why use Kyverno?

1. **Consistent reporting.** All your security findings end up in PolicyReports, queryable with the same `kubectl get policyreport` workflow. PSA is invisible to the rest of your tooling.
2. **Per-namespace customization.** PSA labels namespaces with a profile; Kyverno lets you build per-policy match selectors. Granularity matters when you have a `kube-system` exemption to think about.
3. **`PolicyException` resources.** Sometimes a workload genuinely needs `hostPath` (think Cilium itself). Kyverno's exception model is explicit, audit-friendly, and approval-able through GitOps. PSA doesn't have one — you set the whole namespace to a lower profile.

The policy bundles five rules: disallow privileged, disallow hostPath, require non-root, disallow privilege escalation, drop ALL capabilities.

Apply the policy, then test the rogue pods:

```bash
kubectl apply -f kyverno/04-pod-security-restricted.yaml
kubectl apply -f k8s/bad-pods/01-runs-as-root.yaml      # rejected
kubectl apply -f k8s/bad-pods/05-host-path.yaml         # rejected
kubectl apply -f k8s/bad-pods/06-privileged.yaml        # rejected
```

---

## Scenario 5: Mutate — The Coach Adjusts the Lineup

Clean up from Scenario 4:

```bash
kubectl delete clusterpolicy pod-security-restricted
kubectl delete pods -n kyverno-demo trash-talk-root trash-talk-host-path trash-talk-privileged --ignore-not-found
```

Validation is great for "reject the bad thing." But sometimes you want "fix the bad thing." That's mutation.

Two rules together:

```yaml
# Inject imagePullPolicy: IfNotPresent if missing
- name: set-pull-policy
  mutate:
    foreach:
      - list: "request.object.spec.containers"
        patchStrategicMerge:
          spec:
            containers:
              - name: "{{ element.name }}"
                (image): "{{ element.image }}"
                imagePullPolicy: IfNotPresent

# Inject env=<namespace> label if missing
- name: inject-env-label
  preconditions:
    all:
      - key: "{{ request.object.metadata.labels.env || '' }}"
        operator: Equals
        value: ""
  mutate:
    patchStrategicMerge:
      metadata:
        labels:
          env: "{{ request.namespace }}"
```

Apply the mutation policy and deploy a compliant pod to see the mutations:

```bash
kubectl apply -f kyverno/05-mutate-add-default-labels.yaml
kubectl apply -f kyverno/06-mutate-default-pull-policy.yaml
kubectl apply -f k8s/team-stats-api.yaml

# Check that the mutations were applied
kubectl get pod -n kyverno-demo team-stats-api-74798c8d4b-tfrsz -o yaml | grep -A 2 "imagePullPolicy\|env:"
# imagePullPolicy: IfNotPresent
# env:
# - name: "kyverno-demo"
```

Apply a pod with no `env` label and no `imagePullPolicy` — `kubectl get pod -o yaml` after admission will show both fields injected. The pod author never had to think about them. The platform's defaults are no longer a wiki page; they're code.

This is the difference between **"please remember the env label"** and **"we'll add it for you, here are the rules."** One of those scales.

---

## Scenario 6: Generate — New Franchise Setup

Clean up from Scenario 5:

```bash
kubectl delete clusterpolicy mutate-add-default-labels mutate-default-pull-policy
```

This is the Kyverno feature that most surprises people. When a parent resource appears, Kyverno can **generate child resources** automatically.

The classic use case: a new tenant namespace shows up labeled `tenant=<name>`. You want it to land with:

- a default-deny `NetworkPolicy`
- a `ResourceQuota`
- a `LimitRange`

Without Kyverno, you'd either ship a Helm chart per tenant or hope the tenant remembers. With Kyverno, one ClusterPolicy does it:

```yaml
- name: generate-default-deny-netpol
  match:
    any:
      - resources:
          kinds: [Namespace]
          selector:
            matchExpressions:
              - key: tenant
                operator: Exists
  generate:
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    name: default-deny-all
    namespace: "{{request.object.metadata.name}}"
    synchronize: true
    data:
      spec:
        podSelector: {}
        policyTypes: [Ingress, Egress]
```

`synchronize: true` is the part that earns its keep — Kyverno **reconciles drift**. If a tenant edits the generated NetworkPolicy, Kyverno reverts it. You get baseline-as-code that defends itself.

Apply the policy first, then create the tenant namespace:

```bash
kubectl apply -f kyverno/07-generate-tenant-defaults.yaml
kubectl apply -f k8s/tenant-namespace.yaml

kubectl get networkpolicy,resourcequota,limitrange -n tenant-hawks
# NAME                                         POD-SELECTOR   AGE
# networkpolicy.networking.k8s.io/default-deny-all   <none>    4s
# NAME                          AGE   REQUEST                    LIMIT
# resourcequota/tenant-quota    4s    requests.cpu: 0/2, ...     limits.cpu: 0/4, ...
# NAME                       CREATED AT
# limitrange/tenant-limits   2026-06-02T...
```

Three resources, materialized automatically. Multiply this by 50 tenant namespaces and you'll see the value.

---

## Scenario 7: Verify Images — Player ID Check (the Cosign Demo)

Clean up from Scenario 6:

```bash
kubectl delete clusterpolicy generate-tenant-defaults
kubectl delete namespace tenant-hawks --ignore-not-found
```

This is the supply-chain story everyone wants to tell right now.

`team-stats-api:v1` was signed by `scripts/03-deploy-app.sh` using a Cosign keypair we generated locally. `trash-talk-bot` was not. We want Kyverno to **only admit signed images.**

```yaml
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-team-stats-api-signature
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [kyverno-demo, "tenant-*"]
      verifyImages:
        - imageReferences:
            - "localhost:5000/team-stats-api:*"
            - "localhost:5000/trash-talk-bot:*"
          mutateDigest: true
          verifyDigest: false
          required: true
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQg...
                      -----END PUBLIC KEY-----
                    rekor:
                      ignoreTlog: true
```

A few important details:

- **`mutateDigest: true`** — when Kyverno verifies the signature, it also rewrites the image reference from `team-stats-api:v1` to `team-stats-api@sha256:...`. That means the kubelet pulls the **exact same digest** that was signed, even if the tag is later moved. This is the difference between "we trusted what was at this tag yesterday" and "we trust this exact byte string."
- **`required: true`** — if no signature is found, fail closed. Without this, a missing signature would default to allowing the pod.
- **`rekor: { ignoreTlog: true }`** — skip the Sigstore transparency log lookup. For a local demo this is essential (no public Rekor entry exists for our local image). In production you'd want `ignoreTlog: false` for keyless signing.

Apply the policy. The signed app passes; the unsigned one is rejected:

```bash
kubectl apply -f kyverno/08-verify-image-signatures.yaml
kubectl apply -f k8s/team-stats-api.yaml               # ✅ admitted
kubectl apply -f k8s/bad-pods/07-unsigned-image.yaml   # ❌ rejected
```

That's a real supply-chain story. An attacker who pushes a malicious image to your registry can't run it without your private key.

---

## Scenario 8: Cleanup — End-of-Game Locker Clear-Out

Clean up from Scenario 7:

```bash
kubectl delete clusterpolicy verify-image-signatures
kubectl delete pods -n kyverno-demo --all --ignore-not-found
```

Kyverno's cleanup-controller is the newest of the four controllers, and it's deceptively powerful. It lets you write a `ClusterCleanupPolicy` that runs on a cron schedule and deletes resources matching a query.

```yaml
apiVersion: kyverno.io/v2
kind: ClusterCleanupPolicy
metadata:
  name: cleanup-completed-pods
spec:
  schedule: "*/1 * * * *"
  match:
    any:
      - resources:
          kinds: [Pod]
          namespaces: [kyverno-demo, "tenant-*"]
  conditions:
    any:
      - key: "{{ target.status.phase }}"
        operator: Equals
        value: "Succeeded"
      - key: "{{ target.status.phase }}"
        operator: Equals
        value: "Failed"
```

Apply the cleanup policy and test it:

```bash
kubectl apply -f kyverno/09-cleanup-old-pods.yaml

# Create a test Job to verify cleanup
kubectl create job test-job --image=busybox -n kyverno-demo -- sh -c 'echo "done"; exit 0'

# Watch for the pod to appear in Succeeded phase, then disappear within ~60 seconds
kubectl get pods -n kyverno-demo -w
```

Every minute, the cleanup-controller deletes pods in `Succeeded` or `Failed` phase. Run a Job, watch the completed pod disappear within ~60 seconds.

This solves the "why is my dev cluster full of `Job-foo-xxxxx` pods from three months ago" problem with three lines of YAML.

---

## Scenario 9: Policy Reports — The Referee's Report

Clean up from Scenario 8 to prepare for the full baseline:

```bash
kubectl delete clustercleanuuppolicy cleanup-completed-pods
kubectl delete jobs -n kyverno-demo --all --ignore-not-found
```

The deep reason to use Kyverno over PSA: **everything ends up in a `PolicyReport`.**

When multiple policies are active and violations occur, Kyverno automatically generates PolicyReports:

```bash
kubectl get policyreport -A
# NAMESPACE      NAME                    PASS   FAIL   WARN   ERROR   SKIP   AGE
# kyverno-demo   cpol-disallow-latest-... 2      0      0      0       0      1m
# kyverno-demo   cpol-require-resources   2      0      0      0       0      1m
# kyverno-demo   cpol-pod-security-restr… 2      0      0      0       0      1m
```

For an auditor question like "show me every pod that violated PSS-restricted in the last 30 days," that's `kubectl get policyreport` plus your usual retention. No screenshot hunt, no ad-hoc `jq` query.

The Policy Reporter UI (which we installed earlier) gives the same data in chart form:

```bash
kubectl port-forward -n policy-reporter svc/policy-reporter-ui 8082:8080
open http://localhost:8082
```

That UI is the artefact you show the security team during your quarterly review.

---

## Scenario 10: The Full Baseline

Clean up all policies from previous scenarios:

```bash
kubectl delete clusterpolicies --all
kubectl delete clustercleanuuppolicies --all
kubectl delete pods,deployments -n kyverno-demo --all --ignore-not-found
kubectl delete namespace tenant-hawks --ignore-not-found
```

Now deploy the complete security baseline with all five Kyverno features together:

```bash
kubectl apply -f kyverno/01-require-labels.yaml
kubectl apply -f kyverno/02-disallow-latest-tag.yaml
kubectl apply -f kyverno/03-require-resources.yaml
kubectl apply -f kyverno/04-pod-security-restricted.yaml
kubectl apply -f kyverno/05-mutate-add-default-labels.yaml
kubectl apply -f kyverno/06-mutate-default-pull-policy.yaml
kubectl apply -f kyverno/07-generate-tenant-defaults.yaml
kubectl apply -f kyverno/08-verify-image-signatures.yaml
kubectl apply -f kyverno/09-cleanup-old-pods.yaml
```

Or use the bundled full baseline:

```bash
kubectl apply -f kyverno/10-full-baseline.yaml
```

The end state:

- **Validate** — labels + tags + resources + PSS restricted
- **Mutate** — sane defaults for `env` label and `imagePullPolicy`
- **Generate** — tenant namespaces get NP + Quota + LR automatically
- **Verify Images** — Cosign signature required
- **Cleanup** — completed pods swept every minute

Now test with the compliant and rogue workloads:

```bash
# Compliant app — passes all policies
kubectl apply -f k8s/team-stats-api.yaml      # ✅ admitted

# Try the rogue pods — all rejected
kubectl apply -f k8s/bad-pods/01-runs-as-root.yaml      # ❌ rejected
kubectl apply -f k8s/bad-pods/02-uses-latest-tag.yaml   # ❌ rejected
kubectl apply -f k8s/bad-pods/03-missing-labels.yaml    # ❌ rejected
kubectl apply -f k8s/bad-pods/04-no-resources.yaml      # ❌ rejected
kubectl apply -f k8s/bad-pods/05-host-path.yaml         # ❌ rejected
kubectl apply -f k8s/bad-pods/06-privileged.yaml        # ❌ rejected
kubectl apply -f k8s/bad-pods/07-unsigned-image.yaml    # ❌ rejected

# View the PolicyReports
kubectl get policyreport -A
kubectl describe policyreport -n kyverno-demo
```

The compliant `team-stats-api` passes everything. Every rogue pod gets rejected by something. Your cluster is now hardened from the door.

---

## What I'd Do Differently in Production

A laptop demo and a production rollout aren't the same thing. A few things I'd change:

1. **Keyless signing.** Use Sigstore Fulcio + Rekor (`cosign sign` with no `--key`) for OIDC-tied signatures. The policy is the same shape but references an `issuer:` and `subject:` instead of a public key. No private key to lose.
2. **Roll out in `Audit` first.** `validationFailureAction: Audit` records violations in PolicyReports without blocking. Run audit-mode for a week, fix the noisy violations, then flip to `Enforce`.
3. **Namespace selectors instead of explicit lists.** Match `kyverno-demo` and `tenant-*` is fine for a demo. In prod, label namespaces with `policy-tier: restricted` and select on the label.
4. **`PolicyException` for the rare valid exceptions.** Some workloads (CNI, CSI) need `hostPath`. Don't lower the bar for everyone; carve a tracked, version-controlled exception for just that workload.
5. **GitOps everything.** Argo CD or Flux for the policies themselves. Policy changes become PRs, reviewable, with the same blast-radius controls as any other YAML.

---

## Key Takeaways

1. **Admission control is the gatekeeper.** Fix at the door, not in post-mortems.
2. **Mutate prevents toil.** "We'll add the label for you" scales; "please remember the label" doesn't.
3. **Generate enables self-service.** A new namespace lands hardened, with zero tickets.
4. **Image verification closes the supply-chain gap.** Cosign signatures + `verifyImages` give you cryptographic assurance.
5. **Background scans surface pre-existing violations.** You find the broken pods before audit day, not during it.
6. **Policy Reports turn YAML into something auditors read.** SOC2 evidence becomes a `kubectl` query.
7. **It's just YAML.** No new language. Diff-able, code-reviewable, GitOps-friendly.

If you're a platform engineer building a portfolio, Kyverno is the policy story I'd tell. It hits cleanly on every DevSecOps theme worth telling — admission control, supply chain, multi-tenancy, compliance reporting — and it does it in YAML that looks like every other Kubernetes manifest in your repo.

The whole demo runs on your laptop in about 30 minutes. Try it, screenshot the Policy Reporter UI, and put it in your README.

---

> **Repo:** [github.com/23seriy/kyverno-in-action](https://github.com/23seriy/kyverno-in-action)
>
> Hit me on Medium or LinkedIn if you build something interesting on top of it.
