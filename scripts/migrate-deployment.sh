#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/migrate-deployment.sh [--binary PATH] [--state PATH]

Adopts the existing .env into a non-secret desired-state file and writes a
reviewable deployment plan. It does not apply the plan or restart services.
EOF
}

binary="${MEDIA_STACK_BIN:-./media-stack}"
state_path="media-stack.yaml"

while (($#)); do
  case "$1" in
    --binary)
      (($# >= 2)) || { echo "ERROR: --binary requires a value." >&2; exit 1; }
      binary="$2"
      shift 2
      ;;
    --state)
      (($# >= 2)) || { echo "ERROR: --state requires a value." >&2; exit 1; }
      state_path="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -f .env ]] || { echo "ERROR: .env was not found. Run this helper from the deployment repository." >&2; exit 1; }
[[ ! -e "$state_path" ]] || { echo "ERROR: $state_path already exists; it was not overwritten." >&2; exit 1; }
[[ -x "$binary" ]] || { echo "ERROR: media-stack binary is not executable: $binary" >&2; exit 1; }

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
env_backup=".env.backup.cli-migration.$timestamp"
plan_dir=".media-stack/plans"
plan_path="$plan_dir/migration-$timestamp.json"

cp -p .env "$env_backup"
mkdir -p "$plan_dir"
chmod 700 .media-stack "$plan_dir"

"$binary" adopt --env .env --write "$state_path" --output yaml >/dev/null
"$binary" plan --state "$state_path" --plan-out "$plan_path"

echo
echo "Existing deployment adopted without applying changes."
echo "Environment backup: $env_backup"
echo "Desired state:      $state_path"
echo "Reviewable plan:    $plan_path"
echo
echo "Review $state_path and the plan above. Apply only after loading session secrets:"
echo "  source ./scripts/set-env.sh --include-tailscale"
echo "  $binary apply --state $state_path --plan $plan_path --yes"
