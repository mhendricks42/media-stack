# CI/CD Validation Pipeline

## Overview

The media_stack project includes automated GitHub Actions workflows to prevent configuration regressions and enforce security policies before code reaches `main`.

## Workflow: Docker Compose Validation

**File:** `.github/workflows/compose-validate.yml`

**Triggers:**
- Push to `main` branch
- Pull requests targeting `main`
- Manual dispatch via GitHub UI
- Changes to:
  - `docker-compose.yml`
  - `compose/**/*.yml` (platform overlays)
  - `.env.example`

### What It Validates

1. **Syntax Validation**
   - Base `docker-compose.yml` parses correctly
   - Linux overlay (`compose/linux.yml`) merges cleanly
   - Windows overlay (`compose/windows.yml`) merges cleanly

2. **Security Policy Enforcement**
   - ✅ All images use pinned tags (no `:latest`)
   - ✅ No hardcoded secrets in compose files
   - ✅ Gluetun healthcheck is enabled (critical VPN dependency)

3. **Environment Completeness**
   - ✅ `.env.example` contains all required variables from compose files

### Running Locally

Before pushing, validate your changes locally:

```bash
# Install docker-compose if not present
docker compose version

# Validate syntax (Linux/macOS)
export NORD_USER=test NORD_PASS=test
docker compose config --quiet

# With Linux overlay
export COMPOSE_FILE=docker-compose.yml:compose/linux.yml
docker compose config --quiet

# Check for :latest tags
grep -E '^\s*image:.*:latest\s*$' docker-compose.yml compose/*.yml

# Check Gluetun healthcheck is uncommented
grep -A 5 'gluetun:' docker-compose.yml | grep healthcheck
```

**Windows (PowerShell):**
```powershell
$env:NORD_USER="test"; $env:NORD_PASS="test"
docker compose config --quiet

# Check for :latest tags
Select-String -Path docker-compose.yml,compose\*.yml -Pattern '^\s*image:.*:latest\s*$'
```

## Benefits

### Prevents Regressions

| Issue | Without CI | With CI |
|-------|-----------|---------|
| Syntax errors | Breaks production deploy | Caught in PR |
| Reverted healthcheck | qBittorrent bypasses VPN | Blocked before merge |
| Unpinned `:latest` tag | Supply-chain risk | Rejected automatically |
| Missing env var | Stack fails to start | Detected pre-merge |

### Enforces Security Policies

The CI pipeline **automatically enforces** the security recommendations from the audit:
- Image tag pinning (Finding H1)
- Gluetun healthcheck enabled (Critical architectural issue)
- No credential exposure

A PR that violates these policies **cannot merge** until fixed.

### Faster Feedback

Developers see validation failures in seconds via GitHub Actions, rather than discovering them during manual deployment.

## GitHub Actions Badge

Add this to your README to show CI status:

```markdown
![Compose Validation](https://github.com/YOUR_USERNAME/media_stack/actions/workflows/compose-validate.yml/badge.svg)
```

## Extending the Pipeline

### Add a new check

Edit `.github/workflows/compose-validate.yml`, add a step:

```yaml
- name: Check for deprecated settings
  run: |
    if grep -q 'OLD_DEPRECATED_VAR' docker-compose.yml; then
      echo "❌ ERROR: OLD_DEPRECATED_VAR is deprecated, use NEW_VAR"
      exit 1
    fi
```

### Add linting

Install `yamllint` or `docker compose config --format json | jq` checks for specific patterns.

### Add tests

Future extension: spin up services, run smoke tests, tear down.

```yaml
- name: Smoke test stack
  run: |
    docker compose up -d gluetun
    sleep 10
    docker compose ps gluetun | grep healthy
    docker compose down
```

## Troubleshooting

### Workflow fails with "NORD_USER missing"

The workflow uses **stub credentials** for syntax validation only. It never connects to real VPN servers.

If you see this error:
1. Check that the `.env` stub creation step ran
2. Ensure `export` statements pass credentials to `docker compose config`

### "No such file: compose/linux.yml"

Ensure your platform overlay files exist in the `compose/` directory. The workflow expects:
- `compose/linux.yml`
- `compose/windows.yml`

### False positive on `:latest` check

If a comment or documentation mentions `:latest`, the grep may match it. Refine the regex or exclude non-compose files:

```bash
grep -E '^\s*image:.*:latest\s*$' docker-compose.yml compose/*.yml
```

The `^\s*image:` anchor ensures we only match actual image declarations.

## Future Enhancements

Planned additions:
- [ ] Dependabot for automated image version bumps
- [ ] Trivy vulnerability scanning on pinned images
- [ ] Automated README sync checks (ensure docs match actual config)
- [ ] Integration test suite (spin up stack, verify services respond)
- [ ] Notification to Discord/Slack on failed main builds

---

**Refs:** Architecture Review ARCHITECTURE_REVIEW.md - Top 3 Immediate Fixes #2
