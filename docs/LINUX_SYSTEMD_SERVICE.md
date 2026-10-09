# Linux systemd Service and Optional Autoheal

This deployment can run as a native Linux service after the initial interactive
setup and bootstrap are complete. The service provides:

- explicit `systemctl` lifecycle control;
- startup after Docker and network readiness;
- startup only after the configured data mount is available;
- Docker boot ordering that protects bind mounts before restart policies run;
- normal Docker `unless-stopped` crash recovery; and
- an optional autoheal overlay for containers that remain running but become
  unhealthy.

## Recovery layers

### Layer 1: Docker restart policies

The Linux target sets `RESTART_POLICY=unless-stopped`, and long-running services
use that policy. Docker restarts an exited container after a crash and restores
it after host reboot.

Confirm Docker is enabled:

```bash
systemctl is-enabled docker
```

Enable it if necessary:

```bash
sudo systemctl enable docker
```

Restart policies only respond when a container exits. They do not repair a
container whose process remains alive while its application or network tunnel
is unhealthy.

### Layer 2: systemd lifecycle and storage ordering

[`systemd/media-stack.service.template`](../systemd/media-stack.service.template)
provides Compose lifecycle control.
[`systemd/docker-storage.conf.template`](../systemd/docker-storage.conf.template)
adds both the repository working directory and configured `DATA_ROOT` as Docker
service requirements.

Both pieces are necessary. `RequiresMountsFor` only on `media-stack.service`
would wait before Compose runs, but Docker's own restart-policy restoration
could otherwise start existing containers before that service. The Docker
drop-in makes both mounts prerequisites for Docker itself, protecting
application configuration under the repository as well as media data.

The installer derives:

- working directory from the current checkout;
- service user from the invoking account;
- service group from that account's primary group; and
- storage requirement from `DATA_ROOT` in `.env`.

Install after the normal Linux setup has successfully completed at least one
`up`, `bootstrap`, and `verify` cycle:

```bash
./stack.sh install-service
```

Use explicit values when automatic detection is not appropriate:

```bash
./stack.sh install-service \
  --user media \
  --group media \
  --working-dir /opt/media-stack \
  --data-root /volume1/data
```

The service user must be able to access Docker. If Docker uses its conventional
socket group:

```bash
sudo usermod -aG docker media
```

Sign out and back in before rerunning the installer.

The installer writes:

```text
/etc/systemd/system/media-stack.service
/etc/systemd/system/docker.service.d/media-stack-storage.conf
```

It then reloads systemd, enables Docker and media-stack, and starts the stack.

Check and control it with:

```bash
systemctl status media-stack
sudo systemctl restart media-stack
sudo systemctl reload media-stack
journalctl -u media-stack -f
```

`stop` stops containers without removing them. `reload` reconciles the current
Compose model with `docker compose up -d --remove-orphans`.

### Tailscale at unattended boot

The Linux overlay sets `TS_AUTH_ONCE=true`. Complete the initial Tailscale
authentication during the ordinary interactive setup:

```bash
source ./scripts/set-env.sh --include-tailscale
./stack.sh up
```

After Tailscale has persisted its identity under `config/tailscale`, unattended
service starts no longer require the reusable auth key. Keep `TS_AUTHKEY` out of
`.env` and systemd unit files.

### Layer 3: optional autoheal

[`compose/autoheal.yml`](../compose/autoheal.yml) adds health checks for:

- Gluetun;
- Prowlarr;
- Sonarr;
- Radarr; and
- Jellyfin.

Only those explicitly labeled services are monitored. The watchdog restarts a
monitored container after Docker marks it unhealthy. Enable it during service
installation:

```bash
./stack.sh install-service --enable-autoheal
```

For an existing service installation, add the overlay to `COMPOSE_FILE`:

```dotenv
COMPOSE_FILE=docker-compose.yml:compose/linux.yml:compose/secrets.yml:compose/autoheal.yml
```

Then validate and reconcile:

```bash
./stack.sh config
sudo systemctl reload media-stack
docker compose ps
```

## Docker socket risk

Autoheal requires `/var/run/docker.sock`. The overlay mounts it read-only, runs
without a network namespace, uses a read-only root filesystem, and watches only
containers labeled `autoheal=true`.

Those controls reduce accidental exposure but do not make the socket
read-only in an authorization sense. A process that can issue requests through
the Docker socket can generally obtain host-root-equivalent control, including
starting privileged containers. The `:ro` mount option only prevents replacing
the socket filesystem entry.

If this risk is unacceptable, do not enable `compose/autoheal.yml`. Docker
restart policies plus the systemd/storage layer still provide crash and reboot
recovery.

## Reboot test

Test recovery deliberately after installation:

```bash
sudo reboot
```

After the host has had time to mount storage and start services:

```bash
systemctl status media-stack
./stack.sh ps
./stack.sh verify
```

With autoheal enabled:

```bash
docker compose ps
docker compose logs --tail=100 autoheal
```

All expected services should be running, Gluetun should be healthy, and
`verify` should confirm that Gluetun egress differs from the host.

## NAS power recovery

systemd cannot power on a host after utility power returns. Enable the
platform's firmware or control-panel setting for automatic power-on after an
outage. On UGOS, this is under:

```text
Control Panel -> Hardware -> Auto power-on after outage
```

Names vary on other NAS platforms.

## Updating the installed unit

Rerun the installer after moving the checkout, changing `DATA_ROOT`, changing
the service account, or updating the repository's unit templates:

```bash
./stack.sh install-service
```

The generated files are replaced by `install`, followed by
`systemctl daemon-reload`.

## Disable or uninstall

Disable service management without deleting containers or data:

```bash
sudo systemctl disable --now media-stack
```

Remove the units:

```bash
sudo rm /etc/systemd/system/media-stack.service
sudo rm /etc/systemd/system/docker.service.d/media-stack-storage.conf
sudo systemctl daemon-reload
```

Removing the Docker drop-in takes effect on the next Docker start. Do not remove
application configuration, data, or VPN secret files as part of unit cleanup.

To disable autoheal, remove `compose/autoheal.yml` from `COMPOSE_FILE`, then:

```bash
sudo systemctl reload media-stack
docker compose rm -s -f autoheal
```

## Troubleshooting

### Service fails at `ExecStartPre`

Run the same render as the service account:

```bash
docker compose config --quiet
```

Confirm `.env`, Compose overlays, and VPN secret files exist in the installed
working directory.

### Data mount does not exist

`RequiresMountsFor` can only order a mount known to systemd, such as one declared
in `/etc/fstab` or a generated `.mount` unit. Check:

```bash
findmnt "$(awk -F= '$1 == "DATA_ROOT" {print $2}' .env)"
systemctl list-units --type=mount
```

Fix the host mount definition rather than creating an empty replacement
directory.

### Service user cannot access Docker

```bash
sudo -u <service-user> docker info
ls -l /var/run/docker.sock
```

Grant only the intended service account access. Docker socket access is
host-root-equivalent.

### Container repeatedly autoheals

Autoheal is responding to a symptom. Inspect health and application logs before
raising retry thresholds:

```bash
docker inspect --format '{{json .State.Health}}' "$(docker compose ps -q sonarr)"
docker compose logs --tail=200 sonarr
docker compose logs --tail=200 autoheal
```

Disable the overlay while diagnosing a restart loop if necessary.
