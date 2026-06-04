# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Initial project setup with comprehensive GitHub standards

### Changed
- (Unreleased items go here)

### Deprecated
- (If any features are deprecated, list them here)

### Removed
- (If any features are removed, list them here)

### Fixed
- (Bug fixes go here)

### Security
- (Security fixes go here)

---

## [1.0.0] — 2026-06-03

### Added

#### Documentation
- **CLAUDE.md** — Developer guide with architecture, file structure, and common tasks
- **CONTRIBUTING.md** — Contribution guidelines and development workflow
- **TESTING.md** — Manual and automated testing procedures
- **TROUBLESHOOTING.md** — Comprehensive troubleshooting guide for common issues
- **SECURITY.md** — Security policies and responsible disclosure process
- **CODE_OF_CONDUCT.md** — Community standards and code of conduct
- **CHANGELOG.md** — This file

#### CI/CD
- **GitHub Actions workflow** (`.github/workflows/validate.yml`) with:
  - Shell script linting (shellcheck)
  - YAML validation (yamllint)
  - Kyverno policy syntax validation
  - Dockerfile linting (hadolint)
  - Python code validation
  - Markdown linting
- **GitHub issue templates** for bug reports and feature requests
- **GitHub pull request template** with testing checklist
- **Dependabot configuration** for automated dependency updates
- **Project governance document** (`.github/GOVERNANCE.md`)

#### Development Tools
- **Shell configuration** (`.shellcheckrc`) for script validation
- **Markdown linting configuration** (`.markdownlint.json`)

### Core Features (Initial Release)

#### Scripts
- `01-install-prerequisites.sh` — Install Homebrew tools (minikube, kubectl, helm, kyverno, cosign, crane, jq)
- `02-start-cluster.sh` — Create Minikube cluster with Kyverno and Policy Reporter
- `03-deploy-app.sh` — Build images, sign with Cosign, deploy compliant app
- `04-demo-scenarios.sh` — 11 interactive scenarios demonstrating Kyverno features
- `05-teardown.sh` — Clean up cluster and remove policies

#### Demo Scenarios
1. **Baseline** — No policies; rogue pods admitted
2. **Require Labels** — Enforce team and env labels
3. **No :latest** — Reject latest image tags
4. **Require Resources** — Enforce CPU/memory requests and limits
5. **Pod Security Restricted** — Enforce PSS "restricted" profile
6. **Mutate** — Auto-inject env label and imagePullPolicy
7. **Generate** — Auto-create NetworkPolicy, ResourceQuota, LimitRange in new namespaces
8. **Verify Image Signatures** — Cosign signature verification
9. **Cleanup** — TTL-based deletion of completed pods
10. **Policy Reports** — Background scans and violation visibility
11. **Full Baseline** — All policies active in production configuration

#### Applications
- **team-stats-api** — Compliant Flask app with:
  - Required labels (team, env)
  - Pinned image tag
  - Resource requests and limits
  - Non-root user (UID 10001)
  - Dropped capabilities
  - Cosign signature
- **trash-talk-bot** — Base image for seven bad-pod variants

#### Policies
- `01-require-labels.yaml` — Validate required labels
- `02-disallow-latest-tag.yaml` — Validate image tag pinning
- `03-require-resources.yaml` — Validate resource requests/limits
- `04-pod-security-restricted.yaml` — Enforce Pod Security Standards restricted profile
- `05-mutate-default-pull-policy.yaml` — Mutate imagePullPolicy
- `06-mutate-add-default-labels.yaml` — Mutate default env label
- `07-generate-tenant-defaults.yaml` — Generate NetworkPolicy, ResourceQuota, LimitRange
- `08-verify-image-signatures.yaml` — Verify Cosign signatures
- `09-cleanup-old-pods.yaml` — Delete completed pods on schedule
- `10-full-baseline.yaml` — Composite production policy

### Features

- ✅ **Educational focus** — NBA arena metaphor for clarity
- ✅ **Fully automated** — Single-command setup and demo
- ✅ **Production-ready policies** — Real-world security patterns
- ✅ **Image signing** — Cosign workflow demonstration
- ✅ **Multi-scenario coverage** — 11 independent, sequential scenarios
- ✅ **Cross-platform** — macOS Homebrew support
- ✅ **Well-documented** — Comprehensive README and docs
- ✅ **Community-ready** — Contributing guidelines, code of conduct, security policy

### Tested With

- **Kubernetes** — v1.32.0
- **Kyverno** — v1.13.0
- **Minikube** — latest
- **macOS** — 13.0+
- **Docker Desktop** — latest
- **Python** — 3.12
- **Cosign** — v2.x

---

## How to Use This Changelog

When contributing:
1. Add your changes to the **[Unreleased]** section
2. Use categories: Added, Changed, Deprecated, Removed, Fixed, Security
3. Keep entries brief and user-focused
4. Link to related issues/PRs: `([#123](https://github.com/23seriy/kyverno-in-action/issues/123))`

When releasing:
1. Rename **[Unreleased]** to **[VERSION] — YYYY-MM-DD**
2. Add new **[Unreleased]** section
3. Update links at bottom: `[Unreleased]: https://github.com/23seriy/kyverno-in-action/compare/v1.0.0...HEAD`

---

## Semantic Versioning

- **MAJOR** (1.x.0) — Breaking changes (incompatible script changes, major Kyverno version)
- **MINOR** (x.1.0) — New features (new scenarios, policies)
- **PATCH** (x.x.1) — Bug fixes (script fixes, documentation, typos)

---

[Unreleased]: https://github.com/23seriy/kyverno-in-action/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/23seriy/kyverno-in-action/releases/tag/v1.0.0
