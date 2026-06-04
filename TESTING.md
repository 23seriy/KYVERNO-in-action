# Testing Guide

This document describes how to test kyverno-in-action and validate changes before submitting a pull request.

## Automated Testing

### Local Validation

Before pushing, run the validation suite locally:

```bash
# Check shell scripts
shellcheck -x scripts/*.sh

# Validate YAML
for file in k8s/**/*.yaml kyverno/*.yaml; do
  kubectl apply -f "$file" --dry-run=client -o yaml > /dev/null && echo "✓ $file" || echo "✗ $file"
done

# Check Python syntax
python -m py_compile apps/team-stats-api/app.py apps/trash-talk-bot/app.py

# Lint Dockerfiles (if hadolint installed)
hadolint apps/team-stats-api/Dockerfile apps/trash-talk-bot/Dockerfile
```

### GitHub Actions

The repository includes automated validation via GitHub Actions (`.github/workflows/validate.yml`). Checks run on every push and pull request:

- **Shell linting** — `shellcheck` validates all scripts
- **YAML validation** — `yamllint` checks Kubernetes manifests and policies
- **Kyverno policy syntax** — `kyverno-cli apply` validates policy structure
- **Dockerfile linting** — `hadolint` checks Dockerfiles
- **Python validation** — syntax check and optional linting
- **Documentation completeness** — ensures all required files exist

## Manual Testing

### Full Demo Run

The most comprehensive test is running the full demo:

```bash
./scripts/01-install-prerequisites.sh
./scripts/02-start-cluster.sh
./scripts/03-deploy-app.sh
./scripts/04-demo-scenarios.sh
./scripts/05-teardown.sh
```

**Expected output:** All 11 scenarios complete with ✅ Admitted/Rejected checks passing.

**Time:** ~20 minutes (depends on network speed for downloads)

### Single Policy Test

Test a policy in isolation without creating cluster resources:

```bash
kyverno apply kyverno/04-pod-security-restricted.yaml --resource k8s/bad-pods/01-runs-as-root.yaml
```

Expected output: `validation rule/runAsNonRoot: PASSED` or `FAILED` (depending on the policy).

This is useful for:
- Validating policy syntax
- Testing policy changes without cluster setup
- CI/CD pipelines

### Scenario-Level Testing

Test a specific scenario by running just that section of the demo script:

```bash
# Set up cluster (if not already done)
./scripts/02-start-cluster.sh
./scripts/03-deploy-app.sh

# Manually run scenario 2 (Require Labels)
kubectl apply -f kyverno/01-require-labels.yaml
kubectl apply -f k8s/bad-pods/03-missing-labels.yaml  # Should be rejected
kubectl apply -f k8s/team-stats-api.yaml              # Should be admitted
```

### Component-Level Testing

#### Test the Registry

```bash
# Verify registry is accessible
REGISTRY_PORT=$(kubectl get svc -n kube-system registry -o jsonpath='{.spec.ports[0].nodePort}')
curl -v http://localhost:$REGISTRY_PORT/v2/

# List images in registry
curl -s http://localhost:$REGISTRY_PORT/v2/_catalog | jq .
```

#### Test Cosign Signing

```bash
# Verify an image signature
cosign verify --key cosign/cosign.pub --insecure-ignore-tlog \
    localhost:5000/team-stats-api:v1

# Expected: prints the signature
# If fails: signature invalid or not signed
```

#### Test Kyverno Webhook

```bash
# Check webhook is registered
kubectl get validatingwebhookconfigurations

# Check admission controller logs
kubectl logs -n kyverno deploy/kyverno-admission-controller -f

# Apply a resource while watching logs to see admission decisions
kubectl apply -f k8s/bad-pods/01-runs-as-root.yaml
```

#### Test Policy Reports

```bash
# Trigger a background scan
kubectl apply -f kyverno/04-pod-security-restricted.yaml
sleep 10

# Check reports
kubectl get policyreport -A
kubectl describe policyreport <name> -n kyverno-demo
```

## Test Cases

### Core Functionality

| Test | Command | Expected Result |
|------|---------|-----------------|
| Install tools | `./scripts/01-install-prerequisites.sh` | All tools installed, versions printed |
| Start cluster | `./scripts/02-start-cluster.sh` | Minikube running, Kyverno deployed, webhook active |
| Deploy app | `./scripts/03-deploy-app.sh` | Images built, signed, deployed; team-stats-api running |
| Run demo | `./scripts/04-demo-scenarios.sh` | All 11 scenarios pass; ✅ checks visible |
| Cleanup | `./scripts/05-teardown.sh` | Cluster deleted, Kyverno uninstalled |

### Policy Validation

| Policy | Good Pod | Bad Pod | Expected |
|--------|----------|---------|----------|
| Require Labels | team-stats-api | 03-missing-labels | ✅ admit, ❌ reject |
| No :latest | team-stats-api | 02-uses-latest-tag | ✅ admit, ❌ reject |
| Require Resources | team-stats-api | 04-no-resources | ✅ admit, ❌ reject |
| Pod Security Restricted | team-stats-api | 01-runs-as-root | ✅ admit, ❌ reject |
| Image Verification | team-stats-api (signed) | 07-unsigned-image | ✅ admit, ❌ reject |
| Mutate | Pod without env label applied | Check labels injected | ✅ env label + imagePullPolicy added |
| Generate | New namespace with tenant=hawks | Check generated resources | ✅ NetworkPolicy + Quota + LimitRange created |
| Cleanup | Completed job pod | Wait 60s, check pod deleted | ✅ pod removed by cleanup-controller |

## Regression Testing

When adding new features, test that existing functionality still works:

1. Run the full `04-demo-scenarios.sh` to ensure all scenarios pass
2. Verify each scenario produces expected admissions/rejections
3. Check policy reports are generated correctly
4. Confirm Policy Reporter UI displays violations

## Testing Checklist for Pull Requests

Before submitting a PR, ensure:

- [ ] `shellcheck -x scripts/*.sh` passes without warnings
- [ ] All YAML files validate: `kubectl apply -f <file> --dry-run=client` succeeds
- [ ] Python apps run: `python -m py_compile apps/*/app.py` succeeds
- [ ] Dockerfiles lint: `hadolint apps/*/Dockerfile` passes (if available)
- [ ] Full demo runs: `./scripts/04-demo-scenarios.sh` completes all 11 scenarios
- [ ] No regressions: all scenarios show expected ✅ Admitted/Rejected results
- [ ] Documentation updated if behavior changed
- [ ] Commit messages follow convention: `[type] description`

## Debugging Failed Tests

### Scripts fail with syntax errors

```bash
bash -n scripts/04-demo-scenarios.sh  # Check syntax without running
bash -x scripts/04-demo-scenarios.sh  # Run with debug output
```

### Policy validation fails

```bash
# Get detailed error
kyverno apply kyverno/04-pod-security-restricted.yaml --resource k8s/bad-pods/01-runs-as-root.yaml -v debug

# Check policy definition
kubectl describe clusterpolicy require-team-and-env-labels
```

### Pods not being admitted/rejected as expected

```bash
# Check webhook is responding
kubectl get validatingwebhookconfigurations
kubectl describe validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg

# Check admission controller logs
kubectl logs -n kyverno deploy/kyverno-admission-controller --tail=50

# Apply pod while watching logs
kubectl apply -f k8s/bad-pods/01-runs-as-root.yaml
```

## CI/CD

The GitHub Actions workflow in `.github/workflows/validate.yml` runs automatically on:
- Push to `main` or `develop`
- All pull requests

It checks:
1. Shell script syntax (shellcheck)
2. YAML structure (yamllint)
3. Kyverno policy syntax (kyverno-cli)
4. Dockerfile quality (hadolint)
5. Documentation completeness
6. Python syntax validation

Failures block merging. Check the workflow output in the PR status checks.

---

Questions about testing? See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) or open an issue! 🛡️
