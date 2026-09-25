# Docker Image Tag Policy

## Security Rationale

Using `:latest` tags creates **supply-chain risk**:
- Automatic pulls can introduce breaking changes without notice
- Compromised upstream images deploy instantly
- No rollback path when something breaks
- Hard to reproduce builds across environments

**Recommendation from Security Audit (Finding H1):** Pin image tags to specific versions.

## Strategy

### 1. LinuxServer.io images (most arr-stack services)
Pin to **dated tags** like `version-4.8.1.8906` or use **digest pinning** for immutability.

LinuxServer.io publishes:
- `:latest` - tracks the latest stable release
- `:version-X.Y.Z` - specific upstream version
- `:version-X.Y.Z-ls123` - includes LinuxServer build number
- Digest (`@sha256:...`) - immutable reference

**Our choice:** Use version tags (e.g., `sonarr:version-4.0.11.2680`) for:
- Human readability
- Easier updates (change version, not hash)
- Still deterministic (version tags don't move)

### 2. Gluetun
Pin to semantic version tags: `v3`, `v3.39`, `v3.39.2` (most to least permissive).

**Our choice:** Pin to **minor version** (`v3.39`) to receive patch updates but prevent breaking changes.

### 3. Recyclarr
Already pinned to major version (`:8`) per upstream recommendation - major version bumps require config migration.

### 4. Other images
- **Seerr**: Pin to semantic version (e.g., `:v4.2.0`)
- **ErsatzTV**: Pin to version tag (upstream publishes tagged releases)

## Update Process

### Check for updates
```bash
# Manual check - compare local version to latest release
docker images | grep lscr.io/linuxserver
# Visit https://github.com/linuxserver/docker-<service>/releases

# Automated check (using regctl/crane)
crane digest lscr.io/linuxserver/sonarr:latest
crane digest lscr.io/linuxserver/sonarr:version-4.0.11.2680
```

### Update procedure
1. **Review changelog** for the new version (upstream GitHub releases)
2. **Update docker-compose.yml** image tag
3. **Test in dev** (`docker compose pull && docker compose up -d`)
4. **Verify services** (health checks, UI access, functionality)
5. **Commit the version bump** with clear changelog reference
6. **Document breaking changes** if config migration is needed

### Monthly update routine
Create a **scheduled routine** (StarNet ROUTINES or calendar reminder):
1. Check for new releases of all pinned images
2. Review changelogs for breaking changes
3. Update tags in a feature branch
4. Test and merge

## Current Pinned Versions

| Service | Image | Current Tag | Latest Check Date |
|---------|-------|-------------|-------------------|
| Gluetun | qmcgaw/gluetun | `v3.39` | 2025-01-XX |
| qBittorrent | lscr.io/linuxserver/qbittorrent | `version-5.0.2` | 2025-01-XX |
| SABnzbd | lscr.io/linuxserver/sabnzbd | `version-4.3.3` | 2025-01-XX |
| Prowlarr | lscr.io/linuxserver/prowlarr | `version-1.28.2.4885` | 2025-01-XX |
| Sonarr | lscr.io/linuxserver/sonarr | `version-4.0.11.2680` | 2025-01-XX |
| Radarr | lscr.io/linuxserver/radarr | `version-5.15.1.9463` | 2025-01-XX |
| Bazarr | lscr.io/linuxserver/bazarr | `version-1.4.5` | 2025-01-XX |
| Jellyfin | lscr.io/linuxserver/jellyfin | `version-10.10.3` | 2025-01-XX |
| ErsatzTV | jasongdove/ersatztv | `v0.9.0` | 2025-01-XX |
| Recyclarr | ghcr.io/recyclarr/recyclarr | `8` | (pinned to major) |
| Seerr | ghcr.io/seerr-team/seerr | `v4.2.2` | 2025-01-XX |

## Example version bump commit
```
chore: update Sonarr to v4.0.12.2711

Changelog: https://github.com/Sonarr/Sonarr/releases/tag/v4.0.12.2711
- Fix: Episode search for specials
- Enhancement: Better duplicate detection

Tested: Service starts cleanly, existing series still index correctly
```

## Emergency Rollback

If an update breaks the stack:
```bash
# 1. Checkout the previous working version
git log --oneline docker-compose.yml  # Find the last working commit
git checkout <commit-hash> docker-compose.yml

# 2. Pull the older image (if already overwritten)
docker compose pull <service>

# 3. Restart affected service
docker compose up -d <service>

# 4. Check logs
docker logs -f media_stack-<service>-1
```

## Benefits

✅ **Reproducible deployments** - same image hash across dev/prod  
✅ **Controlled updates** - review changes before they land  
✅ **Rollback path** - git history = image version history  
✅ **Supply-chain security** - compromised `:latest` doesn't auto-deploy  
✅ **Dependency transparency** - know exactly what you're running  

## Trade-offs

⚠️ **Manual updates** - can't `docker compose pull` blindly  
⚠️ **Update lag** - you must actively check for new versions  
⚠️ **Stale dependencies** - forgetting to update = missing security patches  

**Mitigation:** Set up a monthly update check routine (see above).

---

**Refs:** Security Audit SECURITY_AUDIT.md - Finding H1 (High Priority)
