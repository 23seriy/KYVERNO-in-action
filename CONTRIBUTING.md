# Contributing to kyverno-in-action

Thank you for your interest in contributing! This project aims to be a clear, educational demonstration of Kyverno's capabilities. Whether you're fixing a bug, improving documentation, or adding new scenarios, we appreciate your help.

## Getting Started

1. **Fork and clone** the repository
2. **Create a feature branch** from `main`: `git checkout -b feature/your-feature`
3. **Make your changes** and test them thoroughly
4. **Submit a pull request** with a clear description

## Code of Conduct

This project adheres to a Code of Conduct. Please review [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) before participating.

## Development Workflow

### Before You Start

- Ensure you have the prerequisites installed: Docker Desktop, Minikube, and macOS (scripts use Homebrew)
- Familiarity with Kubernetes and Kyverno policy syntax is helpful but not required

### Testing Your Changes

For **script changes**:
```bash
chmod +x scripts/*.sh
./scripts/02-start-cluster.sh      # Fresh cluster
./scripts/03-deploy-app.sh         # Build and deploy apps
./scripts/04-demo-scenarios.sh     # Run through all scenarios
./scripts/05-teardown.sh           # Clean up
```

For **policy changes**:
```bash
# Test a single policy in isolation without creating cluster resources
kyverno apply kyverno/<policy-file>.yaml --resource k8s/<test-manifest>.yaml
```

For **manifest changes**:
- Update the corresponding YAML in `k8s/` or `kyverno/`
- Run the full demo to ensure nothing breaks

### Shell Script Standards

All shell scripts should:
- Start with `#!/usr/bin/env bash` and `set -euo pipefail`
- Use the project's `info()` and `warn()` helper functions for output
- Include descriptive comments for complex logic
- Pass `shellcheck` without warnings (run `shellcheck scripts/*.sh`)

Example:
```bash
#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "${GREEN}[INFO]${NC} $*"; }

info "This is a clear message"
```

### Kyverno Policy Standards

All policies in `kyverno/` should:
- Have a descriptive comment at the top explaining what the policy does
- Use clear rule names (e.g., `require-team-and-env-labels`)
- Match the pattern: `NN-<short-name>.yaml` where NN is the scenario number
- Be testable against a corresponding bad-pod variant in `k8s/bad-pods/`
- Include annotations for policy documentation

Example:
```yaml
# Team jerseys at the door — enforce team and env labels on all pods
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-and-env-labels
  annotations:
    description: "Require all pods to declare team and env labels"
spec:
  # ... rules follow
```

### Documentation Standards

- Keep the README.md up-to-date with the latest Kubernetes and Kyverno versions
- Document new scenarios in the "Demo Scenarios" section
- Update CLAUDE.md if adding architectural concepts
- Use clear, jargon-free language where possible

## Reporting Issues

### Security Vulnerabilities

**Do not** open a public issue for security vulnerabilities. Please review [SECURITY.md](SECURITY.md) for responsible disclosure.

### Bugs and Feature Requests

Use GitHub Issues with:
- **Clear title**: "Script fails on Minikube M1" is better than "Something broken"
- **Steps to reproduce**: Exact commands and cluster state
- **Expected vs. actual behavior**
- **Environment**: macOS version, Minikube version, Kubernetes version

## Pull Request Process

1. **Update tests** if you change functionality
2. **Run the full demo** and confirm all scenarios pass
3. **Check with `shellcheck`**: `shellcheck scripts/*.sh`
4. **Update docs** if behavior changes
5. **Write a clear PR description** explaining *why* the change is needed

### PR Title Convention

Use the format: `[type] short description`

Types:
- `[docs]` — Documentation-only changes
- `[fix]` — Bug fixes
- `[feature]` — New scenarios or policies
- `[refactor]` — Code cleanup without behavior change
- `[ci]` — CI/CD workflow changes

Example: `[feature] add network policy audit logging scenario`

## Project Goals & Philosophy

This project demonstrates Kyverno through **hands-on examples**, not exhaustive feature coverage. When contributing:

- **Prefer clarity over cleverness** — a simple policy is more educational than a complex one
- **Each scenario should teach one thing** — avoid mixing multiple concepts in a single scenario
- **Test scripts must be reproducible** — they should work the same way on any macOS machine with prerequisites installed
- **Keep the NBA arena metaphor consistent** — use the metaphor when explaining concepts in comments and docs

## Recognition

Contributors will be recognized in:
- The project README's acknowledgments section (if you'd like)
- Individual commit history via GitHub

## Questions?

Open a discussion or an issue if you're unsure about anything. We're here to help!

---

Thank you for helping make kyverno-in-action a better learning resource. 🛡️
