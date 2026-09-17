# media-stack

A self-hosted media automation stack that runs identically on a Linux server and a Windows workstation, so changes can be tested locally before they touch production.

One base Compose file holds everything platform-neutral. Thin overlays add what each platform needs. Switching between them is a single command, and nothing about the pipeline itself changes when you do.

```
./stack.sh use linux     # production
./stack.ps1 use windows  # local test
```

---

## Contents

- [What this runs](#what-this-runs)
- [Architecture](#architecture)
- [How the dual-target setup works](#how-the-dual-target-setup-works)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Secrets](#secrets)
- [Setup: Linux (production)](#setup-linux-production)
- [Setup: Windows (development)](#setup-windows-development)
- [First-run configuration](#first-run-configuration)
- [Everyday commands](#everyday-commands)
- [The two things that break this stack](#the-two-things-that-break-this-stack)
- [Promoting changes from dev to prod](#promoting-changes-from-dev-to-prod)
- [Security model](#security-model)
- [Updates](#updates)
- [Troubleshooting](#troubleshooting)
- [Legal](#legal)

---

## What this runs

| Service | Port | Role |
|---|---|---|
| Gluetun | — | VPN tunnel. Owns the network namespace qBittorrent runs in. |
| qBittorrent | 8080 | Secondary torrent client. No network of its own. |
| SABnzbd | 8081 | Primary Usenet download client. Downloads NZBs from your Usenet provider. |
| Prowlarr | 9696 | Indexer manager. Configure once, syncs to Sonarr and Radarr. |
| Sonarr | 8989 | TV. Monitors series, grabs episodes, renames and upgrades. |
| Radarr | 7878 | Movies. Same, for films. |
| Bazarr | 6767 | Subtitles, per language profile. |
| Jellyfin | 8096 | Media server. Scans, transcodes, streams. |
| ErsatzTV | 8409 | Pseudo-live TV channels and guide data from the local library. |
| Seerr | 5055 | Request UI for the household. |
| Tailscale | — | Remote access. Linux host node or optional Windows container node. |

Seerr is the merged successor to Overseerr and Jellyseerr. Readarr is deliberately absent — the project was archived in 2025.

## Architecture

```
                       Seerr
                         │
                  Sonarr / Radarr ────► Prowlarr ────► NZB and torrent indexers
                    │        │
                    │        └────► qBittorrent inside Gluetun ────► VPN ────► swarm
                    └─────────────► SABnzbd ────► Usenet provider
                         │
                 /data  (one filesystem)
                         │
                     Jellyfin
                         │
                    ErsatzTV
                       │
              TVs, phones, browsers
```

Two network domains live on one host and never talk over the network the way you might expect:

**Gluetun's namespace** contains qBittorrent via `network_mode: service:gluetun`. qBittorrent has no interfaces of its own, so if the tunnel drops it has nowhere to send packets. This is a structural kill switch rather than a setting that can be misconfigured.

**The `medianet` bridge** contains everything else. Sonarr and Radarr prefer SABnzbd at `sabnzbd:8080` for Usenet downloads, and keep qBittorrent at `gluetun:8080` as the secondary torrent client. The arr apps never join the swarm, so they do not need the tunnel.

**`/data`** is the handoff. SABnzbd writes to `/data/usenet`, qBittorrent writes to `/data/torrents`, Sonarr and Radarr import into `/data/media`, Jellyfin reads the finished library, and ErsatzTV reads the same media tree to build pseudo-live channels. Coordination over the bridge, files over the filesystem.

## How the dual-target setup works

Docker Compose reads the `COMPOSE_FILE` variable from `.env`. Set it there and plain `docker compose up -d` picks up the right overlays with no flags:

```
COMPOSE_FILE=docker-compose.yml:compose/linux.yml
COMPOSE_PROJECT_NAME=media
```

On Windows, use `;` as the path separator instead:

```
COMPOSE_FILE=docker-compose.yml;compose/windows.yml
COMPOSE_PROJECT_NAME=media-dev
```

Switching targets means swapping `.env`. That is all `stack.sh use` and `stack.ps1 use` do — copy the selected template over `.env`. You can do it by hand and nothing breaks.

### What each overlay changes

| | Linux (prod) | Windows (dev) |
|---|---|---|
| Project name | `media` | `media-dev` |
| Tailscale | Managed container, host networking | Optional userspace container node; native Windows client remains the host-level option |
| Port binding | `0.0.0.0` (LAN reachable) | `127.0.0.1` (loopback only) |
| Restart policy | `unless-stopped` | `no` |
| GPU | `gpu-intel.yml` or `gpu-nvidia.yml` | `gpu-nvidia.yml` only |
| `DATA_ROOT` | A real path on a real filesystem | Must be inside WSL2 or an ext4 mount |

The base file has no `container_name` anywhere. Names derive from `COMPOSE_PROJECT_NAME`, so a dev and prod stack can run on the same machine without colliding. Refer to services by their Compose name (`docker compose logs sonarr`), not a fixed container name.

### GPU overlays are opt-in

They are separate files rather than commented blocks, because a `devices:` entry pointing at a device that does not exist prevents the container from starting. Append one only after confirming the hardware:

```bash
ls -la /dev/dri                                # Intel: must list renderD128
COMPOSE_FILE=docker-compose.yml:compose/linux.yml:compose/gpu-intel.yml
```

On Windows, the equivalent separator is `;`:

```powershell
$env:COMPOSE_FILE='docker-compose.yml;compose/windows.yml;compose/gpu-nvidia.yml'
```

## Repository layout

```
.
├── docker-compose.yml          # base — never run alone
├── compose/
│   ├── linux.yml               # prod: Tailscale
│   ├── windows.yml             # dev: optional userspace Tailscale node
│   ├── gpu-intel.yml           # optional: QuickSync
│   └── gpu-nvidia.yml          # optional: NVENC
├── env/
│   ├── linux.env.example
│   └── windows.env.example
├── scripts/
│   ├── bootstrap.ps1          # app integrations and qBittorrent setup
│   ├── bootstrap-ui-auth.ps1  # UI login provisioning and verification
│   ├── init-windows-dev.ps1   # WSL data path prep for Windows development
│   ├── import-prowlarr-indexers.ps1
│   ├── set-env.ps1            # interactive Windows session env helper
│   └── set-env.sh             # interactive Bash session env helper
├── config/                     # gitignored — app state lives here
├── stack.sh                    # wrapper (bash)
├── stack.ps1                   # wrapper (PowerShell)
└── .gitignore
```

`config/` and `.env` are gitignored. `.env` holds non-secret deployment settings such as paths, ports, and project name. Secrets are supplied from the shell environment or a secret manager at runtime. `config/` holds databases, API keys, and session tokens, so it also stays out of version control.

## Prerequisites

**Both targets:** Docker Engine 24+ with the Compose plugin. A Usenet provider account for SABnzbd, plus NZB indexer accounts such as OZnzb, DrunkenSlug, or NZBGeek if you use private indexers. A VPN account is still needed for the secondary torrent path; this repo assumes NordVPN. Note that Nord's consumer service does not offer port forwarding, so torrent seeding will rely on outbound connections only.

**Linux:** any distro with Docker. An Intel CPU with QuickSync if you expect to transcode. A Tailscale account. Install PowerShell 7 (`pwsh`) to use `bootstrap` and `import-indexers`; it keeps those automation commands identical on both platforms.

**Windows:** Docker Desktop with the WSL2 backend, plus a real WSL distro such as Ubuntu. Read [the Windows section](#setup-windows-development) before you start — the default of putting data on `C:` does not work. The optional containerized Tailscale node requires a Tailscale auth key supplied in the shell environment.

## Secrets

Do not put NordVPN, Tailscale, UI, or indexer credentials in `.env`. The active `.env` file is only for non-secret deployment settings such as paths, project name, port binding, restart policy, timezone, and LAN subnet.

Secrets are session environment variables. The guided helpers prompt for them and set them only in the current terminal session:

```powershell
.\stack.ps1 env
```

```bash
source ./scripts/set-env.sh
```

For Linux production, include the Tailscale auth key prompt:

```bash
source ./scripts/set-env.sh --include-tailscale
```

PowerShell can also prompt for the Tailscale key if you are preparing a Linux target from Windows:

```powershell
.\stack.ps1 env --include-tailscale
```

Use `--force` to replace values already set in the current shell:

```powershell
.\stack.ps1 env --force
```

```bash
source ./scripts/set-env.sh --force
```

The helper prompts for:

- `NORD_USER`
- `NORD_PASS`
- `QBIT_PASS` for bootstrap automation
- `SABNZBD_USER` / `SABNZBD_PASS`
- `TS_AUTHKEY` for a Tailscale overlay or the optional Windows Tailscale container
- `SONARR_USER` / `SONARR_PASS`
- `RADARR_USER` / `RADARR_PASS`
- `PROWLARR_USER` / `PROWLARR_PASS`
- `BAZARR_USER` / `BAZARR_PASS`
- `JELLYFIN_USER` / `JELLYFIN_PASS`
- `SEERR_EMAIL` for the Seerr administrator linked to Jellyfin

The Bash helper must be sourced, not executed, because only a sourced script can export variables into your current shell. On either platform, closing the terminal clears these session secrets. For production, inject the same variables from a secret manager instead of typing them interactively.

## Setup: Linux (production)

**1. Create the data tree.** One filesystem, three subfolders:

```bash
sudo mkdir -p /data/{usenet/incomplete,usenet/complete/tv,usenet/complete/movies,torrents/incomplete,media/tv,media/movies}
sudo chown -R "$USER":"$USER" /data
```

If media lives on a separate drive, mount that drive *at* `/data`. Do not symlink or bind-mount subfolders in from elsewhere — that defeats hardlinks and the failure is silent.

**2. Enable IP forwarding** for Tailscale subnet routing:

```bash
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-tailscale.conf
sudo sysctl --system
```

**3. Configure.**

```bash
git clone <this-repo> media-stack && cd media-stack
./stack.sh use linux
$EDITOR .env          # set non-secret values
source ./scripts/set-env.sh --include-tailscale
mkdir -p config/seerr && sudo chown -R 1000:1000 config/seerr
```

Seerr always runs as UID 1000 regardless of `PUID`, so its config directory needs that owner explicitly. Keep the same terminal open after `set-env.sh`; the secrets live only in that shell session.

**4. Check the merged file before starting.** This catches typos and missing variables without creating anything:

```bash
./stack.sh config | less
```

**5. Start, generate app configs, then bootstrap.** The first `up` creates each application's config files and API keys. `setup-data` creates the shared data tree. `bootstrap` then configures UI logins, SABnzbd paths, qBittorrent paths/seeding limits, Prowlarr app links, download clients, and root folders.

```bash
./stack.sh up
./stack.sh setup-data
./stack.sh bootstrap
./stack.sh doctor
./stack.sh verify
```

`verify` compares the host's public IP against the one Gluetun sees. If they match, stop and fix it — the tunnel is not carrying qBittorrent's traffic.

**6. Approve the Tailscale subnet route** in the admin console. It is off by default, deliberately: one machine claiming an entire `/24` is a significant grant. While you are there, disable key expiry on the node, or remote access will stop working in six months with no obvious cause.

## Setup: Windows (development)

Windows works, but two things that make this stack good are exactly what Windows breaks. Both are solvable; neither is solvable by ignoring it.

### Hardlinks

Docker Desktop reaches Windows drives through a translation layer that does not support hardlinks. Put `DATA_ROOT` on `C:` and every import silently degrades to a full copy — slow, and briefly doubling disk usage each time. Two working options:

**Inside the WSL2 filesystem** (simplest, fine for testing):

```powershell
.\stack.ps1 init-windows
```

`init-windows` ensures the Ubuntu WSL distro exists, creates `/home/<you>/data/usenet`, `/home/<you>/data/torrents`, and `/home/<you>/data/media`, writes the matching `\\wsl$\Ubuntu\home\<you>\data` path into `.env`, and validates that Docker can mount it. Everything lands in a VHDX that only grows. Acceptable for a test library, wrong for a real one.

If you use a different distro or WSL user, pass them explicitly:

```powershell
.\stack.ps1 init-windows Debian matt
```

Before the Docker mount validation can pass, enable Docker Desktop integration for that distro: Settings → Resources → WSL Integration → enable Ubuntu, then Apply and Restart. This is a Docker Desktop UI setting, not something this repo can reliably toggle for you.

**A dedicated ext4 drive** (correct for anything larger):

```powershell
wsl --mount \\.\PHYSICALDRIVE1 --bare
```

Then partition and format ext4 inside WSL. Real hardlinks, real permissions. The drive leaves Windows entirely while mounted.

### Tailscale

The Windows overlay includes an optional userspace Tailscale container. It registers the Docker stack as its own tailnet node without requiring an interactive Tailscale login on Windows. The auth key remains a session variable and is never written to `.env`:

```powershell
.\stack.ps1 env --include-tailscale
.\stack.ps1 up
docker compose ps tailscale
docker compose exec tailscale tailscale status
```

The Windows `.env` template enables the `tailscale` Compose profile. If you do not want the container node, remove `COMPOSE_PROFILES=tailscale` from `.env` or set it to an empty value. The native [Tailscale Windows client](https://tailscale.com/download/windows) is still the correct choice when the Windows host itself must be a tailnet node or advertise a LAN subnet.

The container joining the tailnet does not automatically publish every Compose service. Use Tailscale Serve to expose individual UIs through the container node, for example:

```powershell
docker compose exec tailscale tailscale serve --http=8989 http://sonarr:8989
docker compose exec tailscale tailscale serve --http=8081 http://sabnzbd:8080
docker compose exec tailscale tailscale serve --http=8096 http://jellyfin:8096
docker compose exec tailscale tailscale serve --http=8409 http://ersatztv:8409
docker compose exec tailscale tailscale serve status
```

Use the resulting Tailscale hostname and port from another tailnet device. Do not advertise the Docker subnet as a Windows LAN subnet from this container; Docker Desktop networking is not the same as native Windows host networking.

### Hardware transcoding

`/dev/dri` is not exposed to WSL2 in a form VAAPI can use, so Intel QuickSync is unavailable in Docker on Windows. NVIDIA passthrough works with the NVIDIA Container Toolkit installed inside the WSL distro — that is what `compose/gpu-nvidia.yml` is for. On an Intel-only machine, expect software transcoding, and lean on direct play.

### Then

```powershell
.\stack.ps1 use windows
.\stack.ps1 init-windows
notepad .env          # confirm non-secret values such as VPN_COUNTRY and LAN_SUBNET
.\stack.ps1 env --include-tailscale
.\stack.ps1 up
.\stack.ps1 setup-data
.\stack.ps1 bootstrap
.\stack.ps1 doctor
.\stack.ps1 verify
```

Keep that PowerShell window open after `.\stack.ps1 env`; the secrets live only in that process. `PUID` and `PGID` come from `id` run **inside your WSL distro**, not PowerShell. On files that live on Windows drives they have no effect at all, which is another reason to keep data out of `/mnt/c`.

## First-run configuration

Order matters — doing it in this sequence avoids re-entering things.

**1. Run bootstrap after first startup.** Run `up` once before `bootstrap`; the apps need to create their `config/` files and API keys first. Bootstrap then configures UI logins, SABnzbd paths, qBittorrent paths/seeding limits, Prowlarr app links, Sonarr/Radarr download clients, and root folders.

On a fresh installation, bootstrap configures forms authentication for qBittorrent, SABnzbd, Sonarr, Radarr, Prowlarr, and Bazarr. It initializes the Jellyfin administrator from `JELLYFIN_USER` / `JELLYFIN_PASS`, then configures Seerr from that Jellyfin administrator using `SEERR_EMAIL`. Passwords are only read from runtime environment variables; qBittorrent uses a salted PBKDF2 hash and Bazarr uses its documented MD5 password hash in their local configuration. No temporary password or manual Web UI configuration is needed. Passwords must be at least six characters long.

```powershell
.\stack.ps1 env
.\stack.ps1 bootstrap
```

```bash
source ./scripts/set-env.sh
./stack.sh bootstrap
```

After bootstrap, Prowlarr syncs indexers to Sonarr and Radarr. SABnzbd is the primary download client and qBittorrent is the secondary fallback:

```text
SABnzbd host: sabnzbd
SABnzbd port: 8080
SABnzbd categories: tv, movies
qBittorrent host: gluetun
qBittorrent port: 8080
Sonarr category: tv
Radarr category: movies
Usenet path: /data/usenet
Torrent path: /data/torrents
```

**2. Configure Prowlarr indexers.** Copy the example, edit it, then import. Disabled entries are skipped, so enable only the NZB and torrent indexers you actually have credentials for:

```powershell
Copy-Item .\indexers.example.json .\indexers.json
notepad .\indexers.json
.\stack.ps1 import-indexers
.\stack.ps1 import-indexers .\indexers.json --dry-run
```

```bash
cp indexers.example.json indexers.json
$EDITOR indexers.json
./stack.sh import-indexers
./stack.sh import-indexers indexers.json --dry-run
```

For private indexer credentials, put environment references in `indexers.json` instead of clear-text secrets:

```json
{
  "indexers": [
    {
      "schemaName": "Some Private Tracker",
      "name": "Some Private Tracker",
      "enable": true,
      "fields": {
        "username": "env:TRACKER_USER",
        "password": "env:TRACKER_PASS"
      }
    }
  ]
}
```

**3. Confirm root folders and hardlinks.** Bootstrap creates Sonarr root folder `/data/media/tv` and Radarr root folder `/data/media/movies`. Under Media Management, confirm **Use Hardlinks instead of Copy** is enabled.

**4. Quality profiles.** Take the defaults on day one. Tune later with [Recyclarr](https://github.com/recyclarr/recyclarr), which syncs [TRaSH Guides](https://trash-guides.info/) profiles automatically — hand-tuning custom formats is a rabbit hole with a well-maintained escape.

**5. Jellyfin** (`:8096`). Add `/data/media/tv` and `/data/media/movies` as libraries. Then in Sonarr and Radarr, Settings → Connect → add Jellyfin so imports trigger an immediate scan.

**6. ErsatzTV** (`:8409`). Add `/data/media` as a local media source, or connect ErsatzTV to Jellyfin if you prefer it to read Jellyfin libraries and metadata. Create collections or smart collections, then create channels and schedules. ErsatzTV exposes M3U tuner and XMLTV guide URLs; add those in Jellyfin under Dashboard → Live TV so the channels appear beside normal Jellyfin content.

Typical internal URLs look like this:

```text
ErsatzTV UI: http://ersatztv:8409
Host UI: http://localhost:8409
Jellyfin tuner URL: http://ersatztv:8409/iptv/channels.m3u
Jellyfin guide URL: http://ersatztv:8409/iptv/xmltv.xml
```

Use ErsatzTV for lean-back channels: shuffled sitcom blocks, network-themed schedules, non-consecutive episodes, marathons, or always-running pseudo-cable channels.

**7. Bazarr** last. Point it at Sonarr and Radarr, create a language profile, let it backfill.

**8. Prove the pipeline with one title.** Add a single show, watch it go from grab to Jellyfin, then confirm the hardlink:

```bash
df -h /data                                    # note usage
ls -l /data/torrents/<file> /data/media/tv/<file>   # link count should be 2
df -h /data                                    # usage should barely move
```

For a direct container check, use semicolons between shell commands:

```bash
docker compose exec -T sonarr sh -lc 'rm -f /data/torrents/hltest.txt /data/media/tv/hltest.txt; echo test > /data/torrents/hltest.txt; ln /data/torrents/hltest.txt /data/media/tv/hltest.txt; stat -c "%h links: %n" /data/torrents/hltest.txt /data/media/tv/hltest.txt; rm -f /data/torrents/hltest.txt /data/media/tv/hltest.txt'
```

If usage jumped by the file size, hardlinks are not working. Fix that before adding anything else.

## Everyday commands

```bash
./stack.sh up                 # start
./stack.sh ps                 # status
source ./scripts/set-env.sh   # prompt for session env vars
./stack.sh setup-data         # create /data/usenet, /data/torrents, and media folders
./stack.sh bootstrap          # wire Prowlarr, Sonarr, Radarr, SABnzbd, and qBittorrent
./stack.sh import-indexers    # import local indexers.json into Prowlarr
./stack.sh doctor             # check Docker, data paths, hardlinks, APIs, and Gluetun
./stack.sh logs sonarr        # follow one service
./stack.sh restart gluetun    # restart one service
./stack.sh config             # print merged compose
./stack.sh verify             # confirm the VPN is carrying torrent traffic
./stack.sh pull               # update images, recreate, prune
./stack.sh backup             # stop, archive config/ and .env, start
./stack.sh down               # stop and remove
```

On Windows, use `.\stack.ps1 init-windows` to prepare WSL-backed storage and `.\stack.ps1 env --include-tailscale` when the optional container node is enabled. `stack.ps1` mirrors these commands on Windows, including `backup`.

Backups and logs are not redacted. Treat backup archives as sensitive because they include `config/`, which can contain app API keys, database files, and session tokens. Be thoughtful when sharing `logs` output from real services.

### Reset For Testing

To recreate containers without deleting images or app configuration:

```powershell
docker compose down
docker compose up -d
```

To test a true first-run bootstrap while keeping images, remove only app state:

```powershell
docker compose down
Remove-Item -Recurse -Force .\config
.\stack.ps1 env
docker compose up -d
.\stack.ps1 setup-data
.\stack.ps1 bootstrap
.\stack.ps1 doctor
```

Linux equivalent:

```bash
docker compose down
rm -rf config
source ./scripts/set-env.sh --include-tailscale
docker compose up -d
./stack.sh setup-data
./stack.sh bootstrap
./stack.sh doctor
```

Do not use `docker compose down --rmi all` unless you intentionally want to remove downloaded images.

## The two things that break this stack

Almost every problem people hit is one of these.

### Hardlinks need one filesystem

Sonarr and Radarr mount **all** of `/data`, not just the media folders. That is not an oversight. Import creates a hardlink so the file appears in both the download folder and the library, consuming space once, letting the download keep seeding independently. Hardlinks only work within a single filesystem.

Mount downloads and media as two separate volumes and the container sees two filesystems. Hardlinks fail, imports fall back to copies, and **nothing reports an error**. If imports are slow and disk usage spikes during them, this is why.

### Path consistency across containers

Every service must see the same host directory at the same container path. If qBittorrent reports a finished file at `/downloads/x.mkv` but Sonarr expects `/data/torrents/x.mkv`, the import fails with "path does not exist" while the file sits right there. The base compose mounts `${DATA_ROOT}:/data` uniformly for exactly this reason. Do not "simplify" it per service.

## Promoting changes from dev to prod

The whole point of the dual target is testing changes safely. What is safe to move is narrower than it looks.

**Safe to copy:** the compose files and overlays (they are the artifact), Recyclarr configuration, and anything expressed as YAML in this repo.

**Not safe to copy:** the `config/` directory. Those SQLite databases contain absolute paths, API keys, download client definitions, and library IDs. Copying `config/sonarr` from a Windows dev box to a Linux server produces an app that references paths that do not exist and a download client it cannot reach.

**A reasonable workflow:**

1. Change compose or overlay files on the dev target.
2. `./stack.ps1 config` — confirm the merged output is what you meant.
3. `./stack.ps1 up` and exercise the affected service.
4. Commit and push.
5. On prod: `git pull`, `./stack.sh config` to re-check under the Linux overlay, `./stack.sh backup`, then `./stack.sh up`.
6. `./stack.sh verify` if anything touched Gluetun.

Application-level settings — quality profiles, indexers, naming schemes — are better managed declaratively with [Recyclarr](https://github.com/recyclarr/recyclarr) or [Buildarr](https://github.com/buildarr/buildarr) than by copying databases. That way they are in the repo too, and dev/prod drift stops being a category of problem.

## Security model

Three paths cross the network edge. Two are outbound-initiated; one is refused.

```
qBittorrent ──► Gluetun ──► VPN exit ──► swarm        (sees the VPN's IP)
your phone  ──► Tailscale mesh ◄── server              (both ends dial out)
internet    ──► router ──╫──  server                   (0 ports forwarded)
```

**Nothing ever listens on your public IP.** That is the highest-value control here, and it is why the arr apps' weak default authentication is tolerable — they are only reachable from inside the tailnet.

Worth being precise about scope: Gluetun controls where qBittorrent's traffic *exits*. It does not isolate it laterally. Gluetun sits on `medianet`, so a compromised qBittorrent can reach Sonarr and Jellyfin on the bridge. The tunnel is a privacy control, not a containment boundary.

### Hardening already applied

- `no-new-privileges:true` on every service
- Jellyfin's media mount is read-only
- Images currently use `latest` tags by default
- No Docker socket mounted anywhere
- Containers run as `PUID`/`PGID`, not root
- Dev binds to loopback only

`cap_drop: ALL` is deliberately omitted. The LinuxServer images use s6-overlay and need `CHOWN`, `SETUID`, `SETGID`, `DAC_OVERRIDE`, and `FOWNER` to start; shipping it enabled would break the stack on first run.

### What to avoid adding

**Do not mount `/var/run/docker.sock`.** Watchtower, Portainer, and some dashboards ask for it. Anything holding that socket can start a privileged container mounting `/`, and is therefore root on the host. It is the single worst amplifier available. If you want automated updates, use a socket proxy with a read-only allowlist, or accept monthly manual pulls.

**Think twice about FlareSolverr.** It is a headless Chromium that visits indexer sites and executes whatever JavaScript they serve. Add it only if an indexer genuinely requires it, and remove it when it does not.

## Updates

```bash
./stack.sh pull
```

With `latest` tags, `pull` can update immediately to newer upstream images. If you prefer deterministic upgrades, pin explicit tags in `docker-compose.yml` and update on your schedule.

Version floors worth knowing:

- **Jellyfin ≥ 10.11.7** — two critical RCEs below this, one unauthenticated (CVE-2026-35033) and one a path traversal to root (CVE-2026-35031).
- **Seerr ≥ 3.1.0** — unauthenticated account registration bypass on Plex-configured instances (CVE-2026-27707).
- **qBittorrent ≥ 5.0.1** — 14 years of ignored SSL certificate validation errors (CVE-2024-51774).

Back up before upgrading. `./stack.sh backup` or `.\stack.ps1 backup` stops the stack, archives `config/` and deployment files, and starts it again. Restoring is a matter of extracting the archive over a fresh clone.

## Troubleshooting

**Bootstrap says `QBIT_PASS` or other UI variables are missing.** Session variables do not survive closing the terminal. Run `.\stack.ps1 env` in the same PowerShell window before `.\stack.ps1 bootstrap`. On Bash, run `source ./scripts/set-env.sh` in the same shell. Use `--force` if you intentionally need to replace previously entered values.

**Windows reports `can't access specified distro mount service` or `ubuntu.sock` is missing.** Run `.\stack.ps1 init-windows` first. If its Docker mount test fails, open Docker Desktop → Settings → Resources → WSL Integration, enable Ubuntu, click Apply and Restart, then rerun `.\stack.ps1 init-windows`. Use a real WSL distro such as Ubuntu, not Docker Desktop's internal `docker-desktop` distro, for `DATA_ROOT`.

**Prowlarr rejects the configured login after bootstrap.** Run `.\stack.ps1 env --force`, enter the intended Prowlarr credentials, then rerun `.\stack.ps1 bootstrap`. Bootstrap recreates the Forms user, restarts Prowlarr, and verifies the login redirect before continuing.

**Everything works on the LAN but hangs over Tailscale.** Gluetun's firewall is dropping return traffic to tailnet clients. `FIREWALL_OUTBOUND_SUBNETS` must include `100.64.0.0/10` — it does in the shipped config, so check that your edited `.env` did not lose it.

**SABnzbd cannot download from Usenet.** Bootstrap wires SABnzbd into Sonarr/Radarr, but you still need a Usenet provider configured in SABnzbd. Use SSL, usually port `563`, and the provider credentials from your Usenet account.

**ErsatzTV opens but Jellyfin has no channels.** ErsatzTV creates channels, but Jellyfin does not discover them automatically. In Jellyfin, add an M3U tuner using `http://ersatztv:8409/iptv/channels.m3u`, then add XMLTV guide data from `http://ersatztv:8409/iptv/xmltv.xml` and refresh guide data.

**`verify` reports matching IPs.** qBittorrent is not in Gluetun's namespace. Check that `network_mode: "service:gluetun"` survived any local edits, and that `./stack.sh config` still shows it.

**Imports are slow and disk usage spikes.** Hardlinks are failing. Confirm `/data` is one filesystem and that both Sonarr and qBittorrent mount `${DATA_ROOT}` at `/data`.

**"Path does not exist" on import.** Path mismatch between the download client's reported path and what Sonarr expects. Both must be `/data/torrents/...`.

**qBittorrent web UI returns "Unauthorized."** qBittorrent 5.x validates the Host header. Set the WebUI's alternative hostname allowlist, or reach it via the address it expects.

**Gluetun healthcheck flapping.** Usually a bad VPN server. Change `VPN_COUNTRY` and restart. Check `./stack.sh logs gluetun` for the actual error before changing anything else.

**Gluetun logs show `AUTH_FAILED`.** The VPN provider rejected the credentials passed through `NORD_USER` and `NORD_PASS`. For NordVPN, use the manual/service credentials for OpenVPN, not necessarily the email/password you use for the website or app. Set them as shell environment variables, restart Gluetun, then run `verify` again.

**Subnet route works at home, breaks at a cafe.** Subnet collision — the cafe's network uses the same range you advertised, and the local route wins. This is why `linux.env.example` suggests `10.73.42.0/24` rather than `192.168.1.0/24`. Renumbering later is annoying; do it before you have static leases.

**Tailscale silently stopped working after months.** Node key expiry. Disable it on the node in the admin console.

## Legal

This is general-purpose automation. It searches indexes, talks to a download client, renames files, and serves a library. There is nothing infringing about any of that, and there are entirely legitimate uses: organising your own disc rips, managing public-domain and Creative Commons material, keeping self-produced media sorted.

What you point the indexers at is your responsibility. This repo does not recommend, configure, or ship any indexer. Check the law where you live.