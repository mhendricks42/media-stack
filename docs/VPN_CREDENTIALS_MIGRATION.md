# VPN Credentials Migration Guide

## Security Issue

**CRITICAL:** VPN credentials passed via environment variables are visible in `docker inspect` output and container metadata. This exposes your NordVPN username and password to anyone with Docker access on your system.

## Solution: File-Based Credentials

Gluetun supports `OPENVPN_USER_FILE` and `OPENVPN_PASSWORD_FILE` which read credentials from mounted files instead of environment variables. These files are:
- Never exposed via `docker inspect`
- Only accessible inside the container
- Excluded from version control via `.gitignore`
- Protected by filesystem permissions

## Migration Steps

### 1. Create secrets directory
```bash
mkdir secrets
chmod 700 secrets  # Linux/macOS only
```

### 2. Write credential files

**Linux/macOS:**
```bash
echo -n "your_nordvpn_username" > secrets/vpn_user
echo -n "your_nordvpn_password" > secrets/vpn_password
chmod 600 secrets/vpn_*
```

**Windows (PowerShell):**
```powershell
# Create directory
New-Item -ItemType Directory -Force -Path secrets

# Write files (no trailing newline)
[System.IO.File]::WriteAllText("secrets\vpn_user", "your_nordvpn_username")
[System.IO.File]::WriteAllText("secrets\vpn_password", "your_nordvpn_password")

# Set restrictive permissions (current user only)
$acl = Get-Acl secrets
$acl.SetAccessRuleProtection($true, $false)
$permission = "BUILTIN\Administrators","FullControl","ContainerInherit,ObjectInherit","None","Allow"
$accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule $permission
$acl.AddAccessRule($accessRule)
$permission = "$env:USERNAME","FullControl","ContainerInherit,ObjectInherit","None","Allow"
$accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule $permission
$acl.AddAccessRule($accessRule)
Set-Acl secrets $acl
```

### 3. Verify files
```bash
# Linux/macOS
ls -la secrets/
cat secrets/vpn_user  # Should show your username with NO newline
cat secrets/vpn_password  # Should show your password with NO newline

# Windows
dir secrets
type secrets\vpn_user
type secrets\vpn_password
```

**IMPORTANT:** Files must contain ONLY the credential text with **no trailing newline**. The `-n` flag (echo) and `WriteAllText` method ensure this.

### 4. Remove shell environment variables

You no longer need `NORD_USER` and `NORD_PASS` in your shell environment.

**Linux/macOS** - remove from `~/.bashrc`, `~/.zshrc`, or wherever you set them:
```bash
unset NORD_USER NORD_PASS
```

**Windows** - remove from system/user environment variables:
```powershell
[Environment]::SetEnvironmentVariable("NORD_USER", $null, "User")
[Environment]::SetEnvironmentVariable("NORD_PASS", $null, "User")
```

### 5. Restart the stack
```bash
docker compose down
docker compose up -d gluetun
docker logs -f gluetun  # Verify VPN connects successfully
```

## What Changed

### docker-compose.yml
```diff
   gluetun:
     volumes:
       - ./config/gluetun:/gluetun
+      - ./secrets:/secrets:ro
     environment:
-      - OPENVPN_USER=${NORD_USER:?Set NORD_USER in your shell environment, not in .env}
-      - OPENVPN_PASSWORD=${NORD_PASS:?Set NORD_PASS in your shell environment, not in .env}
+      - OPENVPN_USER_FILE=/secrets/vpn_user
+      - OPENVPN_PASSWORD_FILE=/secrets/vpn_password
```

### .gitignore
```diff
+# VPN credential files (file-based secrets pattern)
+secrets/
```

## Verification

After migration, verify credentials are no longer exposed:

```bash
# This should NOT show your VPN username or password
docker inspect media_stack-gluetun-1 | grep -i vpn

# These files should exist and contain your credentials
docker exec media_stack-gluetun-1 cat /secrets/vpn_user
docker exec media_stack-gluetun-1 cat /secrets/vpn_password
```

## Security Best Practices

1. **Never commit secrets/ to git** - it's already in .gitignore
2. **Keep filesystem permissions restrictive** (600 for files, 700 for directory on Linux/macOS)
3. **Backup secrets/ separately** from config/ (use encrypted backup)
4. **Rotate credentials** if you ever exposed them via environment variables
5. **Consider a secrets manager** (Vault, SOPS, etc.) for production deployments

## Rollback

If you need to revert to environment variables temporarily:

1. Checkout the previous commit: `git checkout HEAD~1 docker-compose.yml`
2. Set `NORD_USER` and `NORD_PASS` in your shell again
3. `docker compose up -d gluetun`

**DO NOT** run both patterns simultaneously - Gluetun will reject conflicting credential sources.

---

**Refs:** Security Audit SECURITY_AUDIT.md - Finding C1 (Critical)
