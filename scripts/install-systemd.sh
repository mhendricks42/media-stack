#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./stack.sh install-service [options]

Options:
  --user USER          Service account (default: current invoking user)
  --group GROUP        Service group (default: USER's primary group)
  --data-root PATH     Required data mount (default: DATA_ROOT from .env)
  --working-dir PATH   Repository path (default: current repository)
  --enable-autoheal    Add compose/autoheal.yml to COMPOSE_FILE
  --no-start           Install and enable units without starting media-stack
  -h, --help           Show this help

Run the wrapper from the repository as the non-root account that owns the
deployment. The installer uses sudo only for files under /etc and systemctl
operations.
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
invoking_user="${SUDO_USER:-${USER:-}}"
[[ -n "$invoking_user" ]] || fail "Could not determine the invoking user."

service_user="$invoking_user"
service_group=""
data_root=""
working_dir="$repo_root"
enable_autoheal=0
start_service=1

while (($#)); do
  case "$1" in
    --user)
      (($# >= 2)) || fail "--user requires a value."
      service_user="$2"
      shift 2
      ;;
    --group)
      (($# >= 2)) || fail "--group requires a value."
      service_group="$2"
      shift 2
      ;;
    --data-root)
      (($# >= 2)) || fail "--data-root requires a value."
      data_root="$2"
      shift 2
      ;;
    --working-dir)
      (($# >= 2)) || fail "--working-dir requires a value."
      working_dir="$2"
      shift 2
      ;;
    --enable-autoheal)
      enable_autoheal=1
      shift
      ;;
    --no-start)
      start_service=0
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

[[ "$working_dir" = /* ]] || fail "--working-dir must be an absolute path."
[[ -f "$working_dir/.env" ]] || fail "Missing $working_dir/.env. Run ./stack.sh use linux first."
[[ -f "$working_dir/docker-compose.yml" ]] || fail "Missing $working_dir/docker-compose.yml."
[[ -f "$working_dir/systemd/media-stack.service.template" ]] ||
  fail "Missing systemd/media-stack.service.template in $working_dir."
[[ -f "$working_dir/systemd/docker-storage.conf.template" ]] ||
  fail "Missing systemd/docker-storage.conf.template in $working_dir."

if [[ -z "$data_root" ]]; then
  data_root="$(awk -F= '$1 == "DATA_ROOT" {
    sub(/^[^=]*=/, "")
    sub(/\r$/, "")
    print
    exit
  }' "$working_dir/.env")"
fi
[[ "$data_root" = /* ]] || fail "DATA_ROOT must be an absolute Linux path, not '$data_root'."

if [[ -z "$service_group" ]]; then
  service_group="$(id -gn "$service_user")"
fi
id "$service_user" >/dev/null 2>&1 || fail "Unknown service user: $service_user"
getent group "$service_group" >/dev/null 2>&1 || fail "Unknown service group: $service_group"

for value_name in working_dir data_root service_user service_group; do
  value="${!value_name}"
  case "$value" in
    *[[:space:]]* | *%*) fail "$value_name cannot contain whitespace or '%': $value" ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  fail "Docker CLI was not found."
fi
docker_path="$(command -v docker)"
if ! command -v systemctl >/dev/null 2>&1; then
  fail "systemctl was not found; this installer requires systemd."
fi
if ! systemctl cat docker.service >/dev/null 2>&1; then
  fail "docker.service was not found. This installer requires a system-level Docker Engine service."
fi
if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 was not found."
fi

if ! sudo -u "$service_user" docker info >/dev/null 2>&1; then
  fail "$service_user cannot access Docker. Add the account to the Docker socket group, sign out and back in, then retry."
fi

if ((enable_autoheal)); then
  python3 - "$working_dir/.env" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
for index, line in enumerate(lines):
    if not line.startswith("COMPOSE_FILE="):
        continue
    value = line.split("=", 1)[1]
    parts = value.split(":")
    if "compose/autoheal.yml" not in parts:
        parts.append("compose/autoheal.yml")
        lines[index] = "COMPOSE_FILE=" + ":".join(parts)
    break
else:
    raise SystemExit(f"{path} does not define COMPOSE_FILE")
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
  echo "Enabled compose/autoheal.yml in $working_dir/.env."
fi

if ! sudo -u "$service_user" sh -c 'cd "$1" && "$2" compose config --quiet' \
  _ "$working_dir" "$docker_path"; then
  fail "The generated Compose model is invalid. Fix the reported error before installing the service."
fi

tmp_dir="$(mktemp -d)"
trap 'rm -f "$tmp_dir/media-stack.service" "$tmp_dir/media-stack-storage.conf"; rmdir "$tmp_dir"' EXIT

python3 - "$working_dir/systemd/media-stack.service.template" "$tmp_dir/media-stack.service" \
  "$working_dir" "$data_root" "$service_user" "$service_group" "$docker_path" <<'PY'
import pathlib
import sys

source, destination, working_dir, data_root, user, group, docker_path = sys.argv[1:]
text = pathlib.Path(source).read_text(encoding="utf-8")
values = {
    "@@WORKING_DIRECTORY@@": working_dir,
    "@@DATA_ROOT@@": data_root,
    "@@SERVICE_USER@@": user,
    "@@SERVICE_GROUP@@": group,
    "@@DOCKER_PATH@@": docker_path,
}
for token, value in values.items():
    text = text.replace(token, value)
if "@@" in text:
    raise SystemExit("Unresolved placeholder in media-stack.service")
pathlib.Path(destination).write_text(text, encoding="utf-8")
PY

python3 - "$working_dir/systemd/docker-storage.conf.template" "$tmp_dir/media-stack-storage.conf" \
  "$working_dir" "$data_root" <<'PY'
import pathlib
import sys

source, destination, working_dir, data_root = sys.argv[1:]
text = pathlib.Path(source).read_text(encoding="utf-8")
text = text.replace("@@WORKING_DIRECTORY@@", working_dir)
text = text.replace("@@DATA_ROOT@@", data_root)
if "@@" in text:
    raise SystemExit("Unresolved placeholder in media-stack-storage.conf")
pathlib.Path(destination).write_text(text, encoding="utf-8")
PY

if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify "$tmp_dir/media-stack.service"
fi

sudo install -D -m 0644 "$tmp_dir/media-stack.service" /etc/systemd/system/media-stack.service
sudo install -D -m 0644 "$tmp_dir/media-stack-storage.conf" \
  /etc/systemd/system/docker.service.d/media-stack-storage.conf
sudo systemctl daemon-reload
sudo systemctl enable docker.service
sudo systemctl enable media-stack.service

if ((start_service)); then
  sudo systemctl reload-or-restart media-stack.service
fi

echo
echo "Installed media-stack.service for $service_user:$service_group."
echo "Working directory: $working_dir"
echo "Required data mount: $data_root"
if ((start_service)); then
  sudo systemctl --no-pager --full status media-stack.service
else
  echo "The service was not started. Run: sudo systemctl start media-stack"
fi
