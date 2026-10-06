# VPN Credentials Migration Guide

## Security Issue

**CRITICAL:** VPN credentials passed via environment variables are visible in `docker inspect` output and container metadata. This exposes your NordVPN username and password to anyone with Docker access on your system.

## Solution: Docker Compose Secrets

Docker Compose mounts `openvpn_user` and `openvpn_password` read-only at `/run/secrets/`. Gluetun reads those paths by default, with secret files taking precedence over environment variables. The credentials are:
- Never exposed via `docker inspect`
- Only accessible inside the container
- Excluded from version control via `.gitignore`
- Protected by filesystem permissions

## Migration Steps

### 1. Select a target

```bash
./stack.sh use linux
```

This includes `compose/secrets.yml` in `COMPOSE_FILE`. On Windows, run `.\stack.ps1 use windows`.

### 2. Create credential files

The helper prompts interactively, uses `printf` semantics, and applies mode `700` to the directory and `600` to both files on Linux. The PowerShell helper restricts the directory ACL to the current user, SYSTEM, and Administrators:

```bash
./stack.sh init-vpn
```

```powershell
.\stack.ps1 init-vpn
```

If creating the files manually, use `printf`, never `echo`:

```bash
mkdir -p secrets && chmod 700 secrets
printf '%s' 'your_nord_service_user' > secrets/openvpn_user
printf '%s' 'your_nord_service_pass' > secrets/openvpn_password
chmod 600 secrets/openvpn_user secrets/openvpn_password
```

**IMPORTANT:** Files must contain only the credential text with no trailing newline. A newline becomes part of the password and causes `AUTH_FAILED`.

### 3. Remove legacy values

Keep `VPN_USER=` and `VPN_PASS=` blank in `.env`, and remove any `NORD_USER`, `NORD_PASS`, `VPN_USER`, or `VPN_PASS` exports from shell startup files. The secrets overlay explicitly blanks `OPENVPN_USER` and `OPENVPN_PASSWORD` as defense in depth.

### 4. Recreate and verify
```bash
./stack.sh up
./stack.sh verify
```

## What Changed

### compose/secrets.yml
```diff
+secrets:
+  openvpn_user:
+    file: ./secrets/openvpn_user
+  openvpn_password:
+    file: ./secrets/openvpn_password
+
+services:
+  gluetun:
+    secrets:
+      - openvpn_user
+      - openvpn_password
+    environment:
+      OPENVPN_USER: ""
+      OPENVPN_PASSWORD: ""
```

### .gitignore
```diff
+# VPN credential files (file-based secrets pattern)
+secrets/
```

## Verification

After migration, verify credentials are no longer exposed:

```bash
docker inspect "$(docker compose ps -q gluetun)" | grep -i openvpn
```

`OPENVPN_USER=` and `OPENVPN_PASSWORD=` should be empty. The actual values must not appear. Do not print the secret files during verification or paste their contents into support requests.

## Security Best Practices

1. **Never commit secrets/ to git** - it's already in .gitignore
2. **Keep filesystem permissions restrictive** (600 for files, 700 for directory on Linux/macOS)
3. **Backup secrets/ separately** from config/ (use encrypted backup)
4. **Rotate credentials** if you ever exposed them via environment variables
5. **Consider a secrets manager** (Vault, SOPS, etc.) for production deployments

The arr application API keys remain environment variables because those applications do not provide file-based equivalents.
