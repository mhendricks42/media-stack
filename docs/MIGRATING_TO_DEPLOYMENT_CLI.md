# Migrating an Existing Deployment to the `media-stack` CLI

The professional deployment CLI can adopt an existing `.env` without changing
containers, application configuration, media, or secrets. Adoption creates a
non-secret desired-state file and a reviewable plan. Applying that plan remains
a separate, explicit action.

## What migration changes

The migration helper creates:

- `media-stack.yaml`, containing non-secret deployment intent;
- `.media-stack/plans/migration-<timestamp>.json`, containing a reviewed-plan
  candidate; and
- `.env.backup.cli-migration.<timestamp>`, preserving the current environment.

It does not:

- stop or restart containers;
- modify `.env`;
- read secret values into desired state;
- change `config/`, `secrets/`, or media files; or
- install or modify the systemd service.

## 1. Build or obtain the CLI

Build on a machine with Go 1.22 or newer.

Windows:

```powershell
go test ./...
go build -o media-stack.exe ./cmd/media-stack
```

Linux:

```bash
go test ./...
go build -o media-stack ./cmd/media-stack
chmod +x media-stack
```

Cross-compile an amd64 Linux binary from PowerShell:

```powershell
$env:GOOS = 'linux'
$env:GOARCH = 'amd64'
go build -o dist/media-stack-linux-amd64 ./cmd/media-stack
Remove-Item Env:GOOS, Env:GOARCH
```

Confirm the NAS architecture with `uname -m` before copying a cross-compiled
binary. `x86_64` corresponds to `amd64`; `aarch64` corresponds to `arm64`.

## 2. Preserve current state

Keep the existing application backup process:

```bash
./stack.sh backup
```

The CLI migration helper also preserves `.env`, but it does not duplicate the
application databases under `config/`.

## 3. Run read-only adoption

Linux:

```bash
./scripts/migrate-deployment.sh
```

Use a binary stored elsewhere:

```bash
./scripts/migrate-deployment.sh --binary /usr/local/bin/media-stack
```

Windows:

```powershell
.\scripts\migrate-deployment.ps1
```

Both helpers stop if `media-stack.yaml` already exists.

## 4. Review desired state

Inspect:

```bash
cat media-stack.yaml
```

Adoption maps:

- target platform from `COMPOSE_FILE`;
- storage root from `DATA_ROOT`;
- bind mode from `BIND_ADDR`;
- LAN subnet;
- Jellyfin server name; and
- Moonbase enablement and version settings.

Secrets are represented only by references such as `openvpn-user-file`.
Credential values from `.env`, the process environment, Docker secret files,
and application configuration are never copied into the YAML.

If adoption reports unresolved fields, correct `.env` or create the desired
state with:

```bash
./media-stack configure --profile recommended --platform linux \
  --name home-media --data-root /volume1/media-data \
  --write media-stack.yaml
```

Available profiles are `recommended`, `usenet-only`, `torrent-only`,
`local-only`, and `custom`. Profiles capture intent in this initial release;
the existing Compose topology remains authoritative until service-level profile
pruning is implemented.

## 5. Review the plan

Generate another plan at any time:

```bash
./media-stack plan --state media-stack.yaml \
  --plan-out .media-stack/plans/review.json
```

Planning is read-only. A plan is bound to hashes of desired state and discovered
host state. Apply rejects it if either changes.

For machine-readable output:

```bash
./media-stack plan --state media-stack.yaml --output json
```

## 6. Apply the adopted state

Load the same session secrets used by the existing bootstrap:

```bash
source ./scripts/set-env.sh --include-tailscale
```

Then apply the reviewed plan:

```bash
./media-stack apply --state media-stack.yaml \
  --plan .media-stack/plans/migration-<timestamp>.json --yes
```

Apply uses the existing idempotent wrappers in this order:

1. update non-secret `.env` values;
2. reconcile Compose containers;
3. create the container-backed shared directory tree;
4. rerun application bootstrap; and
5. run deployment verification.

Each step is recorded under `.media-stack/operations/`. Journals are mode `600`
on supported Unix filesystems and are structurally redacted.

## 7. Resume an interrupted operation

After correcting the reported cause:

```bash
./media-stack resume --state media-stack.yaml
```

Resume verifies successful postconditions again. It does not trust journal
status alone, and it rejects a changed desired-state file.

Specify a journal explicitly when necessary:

```bash
./media-stack resume --state media-stack.yaml \
  --journal .media-stack/operations/<operation>.json
```

## 8. Routine commands

```bash
./media-stack status
./media-stack doctor
./media-stack logs jellyfin
./media-stack repair jellyfin
./media-stack repair jellyfin --yes
./media-stack backup --yes
./media-stack update --yes
```

`doctor` is read-only. `repair` prints its plan without changing anything unless
`--yes` is supplied. `update` runs the existing backup command before pulling
and reconciling images.

`restore` and `rollback` intentionally return explicit unsupported errors in
this release. Application database downgrade safety and archive-integrity
validation must be implemented before those commands can be automated safely.

## 9. Roll back CLI adoption

Before apply, rollback is simply:

```bash
rm media-stack.yaml
rm -rf .media-stack
```

The existing `.env`, containers, and configuration were not changed.

After apply, restore the preserved environment only if needed:

```bash
cp .env.backup.cli-migration.<timestamp> .env
./stack.sh config
./stack.sh up
./stack.sh verify
```

Do not delete operation journals until the migrated deployment has passed
normal operation and reboot testing.
