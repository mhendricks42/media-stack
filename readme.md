# media-stack

A self-hosted media automation stack with the same service topology on a Linux server and a Windows workstation, so changes can be tested locally before they touch production.

One base Compose file holds everything platform-neutral. Thin overlays add target-specific networking, storage, restart, and GPU behavior. Switching between them is a single command; the media pipeline stays the same while the host integration changes.

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
| Recyclarr | — | On-demand TRaSH Guides sync for Sonarr and Radarr quality profiles and custom formats. |
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

**`/data`** is the handoff. SABnzbd writes to `/data/usenet`, qBittorrent writes to `/data/torrents`, Sonarr and Radarr import into `/data/media`, Jellyfin reads the finished library, and ErsatzTV reads the same media tree to build pseudo-live channels. Coordination happens over the bridge and files move through the shared filesystem. See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the cited system map, lifecycle diagrams, and subsystem deep-dives.

## How the dual-target setup works

Docker Compose reads the `COMPOSE_FILE` variable from `.env`. Set it there and plain `docker compose up -d` picks up the right overlays with no flags:

```
COMPOSE_FILE=docker-compose.yml:compose/linux.yml:compose/secrets.yml
COMPOSE_PROJECT_NAME=media
```

On Windows, use `;` as the path separator instead:

```
COMPOSE_FILE=docker-compose.yml;compose/windows.yml;compose/secrets.yml
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
COMPOSE_FILE=docker-compose.yml:compose/linux.yml:compose/secrets.yml:compose/gpu-intel.yml
```

On Windows, the equivalent separator is `;`:

```powershell
$env:COMPOSE_FILE='docker-compose.yml;compose/windows.yml;compose/secrets.yml;compose/gpu-nvidia.yml'
```

## Repository layout

```
.
├── ARCHITECTURE.md             # cited architecture and onboarding guide
├── docker-compose.yml          # platform-neutral service graph
├── compose/                    # target, secret, and optional GPU overlays
│   ├── linux.yml / windows.yml
│   ├── secrets.yml
│   └── gpu-intel.yml / gpu-nvidia.yml
├── env/                        # copyable non-secret target templates
│   ├── linux.env.example
│   └── windows.env.example
├── scripts/                    # bootstrap and host setup automation
│   ├── bootstrap.sh / bootstrap.ps1
│   ├── bootstrap-ui-auth.ps1 / bootstrap-jellyfin.ps1
│   ├── bootstrap-seerr.sh / bootstrap-seerr.ps1
│   ├── import-prowlarr-indexers.ps1
│   ├── init-windows-dev.ps1
│   └── set-env.sh / set-env.ps1
├── docs/                       # migration, image policy, and history
├── config/                     # ignored generated application state
├── indexers.example.json       # declarative Prowlarr indexer example
├── recyclarr.example.yml       # declarative TRaSH profile baseline
├── stack.sh / stack.ps1        # operator lifecycle wrappers
└── .gitignore
```

`config/` and `.env` are gitignored. `.env` holds non-secret deployment settings such as paths, ports, and project name. Secrets are supplied from the shell environment or a secret manager at runtime. `config/` holds databases, API keys, and session tokens, so it also stays out of version control.

## Prerequisites

**Both targets:** Docker Engine 24+ with the Compose plugin. A Usenet provider account for SABnzbd, plus NZB indexer accounts such as OZnzb, DrunkenSlug, or NZBGeek if you use private indexers. A VPN account is still needed for the secondary torrent path; this repo assumes NordVPN. Note that Nord's consumer service does not offer port forwarding, so torrent seeding will rely on outbound connections only.

**Linux:** any distro with Docker, Bash, curl, jq, and Python 3. An Intel CPU with QuickSync if you expect to transcode. A Tailscale account. Bootstrap and indexer import are implemented natively for Linux; PowerShell is not required.

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
./stack.sh init-vpn
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

Run `./stack.sh init-vpn` or `.\stack.ps1 init-vpn` separately for NordVPN credentials. The session helper prompts for:

- `QBIT_PASS` for bootstrap automation
- `SABNZBD_USER` / `SABNZBD_PASS`
- optional `NZBGEEK_API_KEY` and `NZBPLANET_API_KEY` for enabled private indexers in `indexers.json`
- `SAB_SERVER_HOST` / `SAB_SERVER_USER` / `SAB_SERVER_PASS` for the primary Usenet provider
- optional `SAB_BACKUP_SERVER_HOST` / `SAB_BACKUP_SERVER_USER` / `SAB_BACKUP_SERVER_PASS` for a backup or block account
- `TS_AUTHKEY` for a Tailscale overlay or the optional Windows Tailscale container
- `SONARR_USER` / `SONARR_PASS`
- `RADARR_USER` / `RADARR_PASS`
- `PROWLARR_USER` / `PROWLARR_PASS`
- `BAZARR_USER` / `BAZARR_PASS`
- `JELLYFIN_USER` / `JELLYFIN_PASS`, plus optional `MOONBASE_TMDB_API_KEY` and `MOONBASE_MDBLIST_API_KEY` integration secrets
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

`init-vpn` stores the Nord OpenVPN credentials in ignored files with no trailing newline and restrictive Linux permissions. Seerr always runs as UID/GID 1000:1000 regardless of `PUID`/`PGID`, so its config directory needs that ownership explicitly. NAS platforms may attach inherited ACLs that override ordinary mode bits; if `ls -ld config/seerr` ends with `+` and Seerr reports `EACCES`, run `sudo setfacl -Rb config/seerr`, restore ownership with `sudo chown -R 1000:1000 config/seerr`, and restrict modes with `sudo chmod -R u+rwX,g+rX,o-rwx config/seerr`. Keep the same terminal open after `set-env.sh`; the remaining bootstrap and Tailscale secrets live only in that shell session.

**4. Check the merged file before starting.** This catches typos and missing variables without creating anything:

```bash
./stack.sh config | less
```

**5. Start, generate app configs, then bootstrap.** The first `up` creates each application's config files and API keys. `setup-data` creates missing shared-data directories with the configured `PUID` and `PGID`; it never changes ownership of existing directories or media. `bootstrap` then configures UI logins, SABnzbd paths, qBittorrent paths/seeding limits, Prowlarr app links, download clients, and root folders.

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

**1. Run bootstrap after first startup.** Run `up` once before `bootstrap`; the apps need to create their `config/` files and API keys first. Bootstrap then configures UI logins, SABnzbd paths and provider servers, qBittorrent paths/seeding limits, Prowlarr app links, Sonarr episode naming and media management, Sonarr/Radarr download clients, Jellyfin server settings, and root folders.

On a fresh installation, bootstrap configures forms authentication for qBittorrent, SABnzbd, Sonarr, Radarr, Prowlarr, and Bazarr. It initializes the Jellyfin administrator from `JELLYFIN_USER` / `JELLYFIN_PASS`, applies the Jellyfin baseline, installs and configures the pinned Moonbase server plugin for Moonfin, then configures Seerr from that Jellyfin administrator using `SEERR_EMAIL` and verifies Seerr's API key. Passwords are only read from runtime environment variables; qBittorrent uses a salted PBKDF2 hash and Bazarr uses its documented MD5 password hash in their local configuration. No temporary password or manual Web UI configuration is needed. Passwords must be at least six characters long.

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

Radarr download clients are baselined too: SABnzbd uses `movies`, priority `1`, completed download handling on, and default movie priorities; qBittorrent uses `movies`, post-import category `movies-imported`, priority `2`, completed download handling off, and default movie priorities.

Sonarr media management is also baselined from the current dev config: episode renaming is enabled, hardlinks are enabled, proper/repack upgrades are preferred, season folders are `Season {season:00}`, specials go under `Specials`, and anime names include series year, season/episode, absolute number, custom formats, quality, media info, and release group.

Jellyfin is baselined during bootstrap too: the server name defaults to `Media Stack` unless `JELLYFIN_SERVER_NAME` is set, `Movies` points at `/data/media/movies`, `Shows` points at `/data/media/tv`, Live TV gets the ErsatzTV M3U tuner `http://ersatztv:8409/iptv/channels.m3u`, and guide data gets the ErsatzTV XMLTV feed `http://ersatztv:8409/iptv/xmltv.xml`.

For more than two SABnzbd servers, inject `SAB_SERVERS_JSON` from your secret manager instead of using the interactive helper. It accepts either an array or an object with a `servers` array. Each server needs `host`, `username`, and `password`; optional fields include `name`, `displayName`, `port`, `connections`, `ssl`, `enable`, `priority`, `optional`, `required`, `retention`, and `sslVerify`.

**2. Configure Prowlarr indexers.** Copy the example and edit it before bootstrap. Bootstrap imports `indexers.json` after creating Prowlarr's Sonarr/Radarr links; entries disabled in the file or missing their optional `env:` key are skipped. To rerun the idempotent importer after changing indexers or setting an API key:

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

**4. Quality profiles.** Sync them from [TRaSH Guides](https://trash-guides.info/) instead of hand-tuning custom formats:

```powershell
.\stack.ps1 sync-profiles --preview
.\stack.ps1 sync-profiles
```

```bash
./stack.sh sync-profiles --preview
./stack.sh sync-profiles
```

The first run copies `recyclarr.example.yml` to `config/recyclarr/recyclarr.yml`, then applies it. The shipped file syncs a 1080p WEB profile plus the full anime set — every Anime BD and Web tier, Anime Raws, Anime LQ Groups, and Uncensored — with TRaSH's intended scores. Edit `config/recyclarr/recyclarr.yml` to change which templates apply, then re-run.

The wrappers read the Sonarr and Radarr API keys out of `config/` and inject them as environment variables, so no key is ever written into the Recyclarr config.

The negative scores on Anime Raws and Anime LQ Groups are what actually keeps unsubbed and low-quality anime releases out of the library; the profile's minimum format score rejects them rather than merely depranking them. Recyclarr owns the formats and profiles it manages, so anything you created by hand under the same names is overwritten — run `--preview` first.

[Buildarr](https://github.com/buildarr/buildarr) covers the same ground if you want indexers and naming schemes declarative too.

**5. Jellyfin and Moonbase** (`:8096`). Bootstrap creates the `Movies` and `Shows` libraries, sets the server name, and adds ErsatzTV as an M3U tuner with XMLTV guide data. It also merges the official Moonbase catalog into Jellyfin's repository list, installs the `MOONBASE_VERSION` pinned in `.env`, restarts Jellyfin when installation state changes, merges the Moonbase plugin configuration, and verifies `/Moonfin/Ping`. Moonbase settings sync and the Seerr integration default to enabled; the server-to-server URLs default to `http://seerr:5055` and `http://jellyfin:8096`. Set `MOONBASE_ENABLED=false` to skip plugin management, or change the `MOONBASE_*` values in `.env` before bootstrap. Optional TMDB and MDBList keys come from the current shell, never `.env`. After Seerr is configured, bootstrap requests Moonbase webhook reprovisioning. Then in Sonarr and Radarr, Settings → Connect → add Jellyfin so imports trigger an immediate scan.

**6. ErsatzTV** (`:8409`). Add `/data/media` as a local media source, or connect ErsatzTV to Jellyfin if you prefer it to read Jellyfin libraries and metadata. Create collections or smart collections, then create channels and schedules. ErsatzTV exposes M3U tuner and XMLTV guide URLs, and bootstrap adds those URLs to Jellyfin Live TV.

Typical internal URLs look like this:

```text
ErsatzTV UI: http://ersatztv:8409
Host UI: http://localhost:8409
Jellyfin tuner URL: http://ersatztv:8409/iptv/channels.m3u
Jellyfin guide URL: http://ersatztv:8409/iptv/xmltv.xml
```

Use ErsatzTV for lean-back channels: shuffled sitcom blocks, network-themed schedules, non-consecutive episodes, marathons, or always-running pseudo-cable channels.

**7. Bazarr** last. Point it at Sonarr and Radarr, create a language profile, let it backfill.

**8. Seerr** is auto-configured by bootstrap: API keys are read from Sonarr and Radarr config, the `Sonarr`/`Radarr` servers use the Docker hostnames `sonarr:8989` and `radarr:7878`, scan/sync is enabled, and the TRaSH quality profiles are selected. After bootstrap restarts Seerr, it will be ready to request content. Log in with your Jellyfin administrator account (configured in `JELLYFIN_USER`/`JELLYFIN_PASS`), or use the email in `SEERR_EMAIL` if auto-initialization is disabled.

**9. Prove the pipeline with one title.** Add a single show, watch it go from grab to Jellyfin, then confirm the hardlink:

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
./stack.sh bootstrap          # configure authentication, apps, clients, Moonbase, Jellyfin, and Seerr
./stack.sh import-indexers    # import local indexers.json into Prowlarr
./stack.sh sync-profiles      # sync TRaSH quality profiles and custom formats
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

Application-level settings — quality profiles, indexers, naming schemes — are better managed declaratively than by copying databases. `recyclarr.example.yml` and `indexers.example.json` are in the repo for exactly that reason: promote the file, run `./stack.sh sync-profiles` or `./stack.sh import-indexers` on prod, and dev/prod drift stops being a category of problem. [Buildarr](https://github.com/buildarr/buildarr) extends the same idea further if you want it.

## Security model

Three paths cross the network edge. Two are outbound-initiated; one is refused.

```
qBittorrent ──► Gluetun ──► VPN exit ──► swarm        (sees the VPN's IP)
your phone  ──► Tailscale mesh ◄── server              (both ends dial out)
internet    ──► router ──╫──  server                   (0 ports forwarded)
```

**This repository does not configure router port forwarding.** Linux binds service ports to `0.0.0.0` for LAN access, while Windows development binds to `127.0.0.1`; whether a Linux service is publicly reachable still depends on the host firewall, router, and deployment environment. Bootstrap enables application authentication rather than relying on network placement alone.

Worth being precise about scope: Gluetun controls where qBittorrent's traffic *exits*. It does not isolate it laterally. Gluetun sits on `medianet`, so a compromised qBittorrent can reach Sonarr and Jellyfin on the bridge. The tunnel is a privacy control, not a containment boundary.

### Hardening already applied

- `no-new-privileges:true` on application services except the network-control containers Gluetun and Tailscale
- Jellyfin's media mount is read-only
- Every current image reference, including Recyclarr and Tailscale, uses a floating `latest` tag
- No Docker socket mounted anywhere
- LinuxServer application images receive `PUID`/`PGID`; Recyclarr has an explicit user, while Gluetun and Tailscale retain the privileges needed for network control
- Dev binds to loopback only

`cap_drop: ALL` is deliberately omitted. The LinuxServer images use s6-overlay and need `CHOWN`, `SETUID`, `SETGID`, `DAC_OVERRIDE`, and `FOWNER` to start; shipping it enabled would break the stack on first run. Gluetun has an active local health endpoint check, so qBittorrent's `condition: service_healthy` gates startup on VPN health. This branch has no active CI workflow, so validate both target overlays manually with `config`.

### What to avoid adding

**Avoid mounting `/var/run/docker.sock`.** Watchtower, Portainer, and some dashboards ask for it. Anything holding that socket can start a privileged container mounting `/`, and is therefore root on the host. The optional autoheal overlay is a narrowly scoped exception: it is disabled by default, watches only labeled services, and still carries host-root-equivalent risk even with a `:ro` mount. See [the Linux systemd and autoheal guide](docs/LINUX_SYSTEMD_SERVICE.md) before enabling it.

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

**SABnzbd cannot download from Usenet.** Rerun `./stack.ps1 env --force` or `source ./scripts/set-env.sh --force`, set the `SAB_SERVER_*` provider values, then rerun bootstrap. Provider server credentials are read from the shell and written into SABnzbd's local config, not committed to this repo.

**ErsatzTV opens but Jellyfin has no channels.** ErsatzTV creates channels, but Jellyfin does not discover them automatically. In Jellyfin, add an M3U tuner using `http://ersatztv:8409/iptv/channels.m3u`, then add XMLTV guide data from `http://ersatztv:8409/iptv/xmltv.xml` and refresh guide data.

**`verify` reports matching IPs.** qBittorrent is not in Gluetun's namespace. Check that `network_mode: "service:gluetun"` survived any local edits, and that `./stack.sh config` still shows it.

**Imports are slow and disk usage spikes.** Hardlinks are failing. Confirm `/data` is one filesystem and that both Sonarr and qBittorrent mount `${DATA_ROOT}` at `/data`.

**"Path does not exist" on import.** Path mismatch between the download client's reported path and what Sonarr expects. Both must be `/data/torrents/...`.

**qBittorrent web UI returns "Unauthorized."** qBittorrent 5.x validates the Host header. Set the WebUI's alternative hostname allowlist, or reach it via the address it expects.

**qBittorrent does not start, or `doctor` / `verify` reports that Gluetun is not healthy.** qBittorrent waits for Gluetun's local health endpoint. Repeated failures usually indicate a bad VPN server, failed tunnel, or unavailable Gluetun health server. Check `./stack.sh logs gluetun` before changing anything else.

**Gluetun logs show `AUTH_FAILED`.** The VPN provider rejected `secrets/openvpn_user` or `secrets/openvpn_password`. For NordVPN, use the manual/service credentials for OpenVPN, not necessarily the email/password you use for the website or app. Rerun `./stack.sh init-vpn` (or `.\stack.ps1 init-vpn`), recreate Gluetun, then run `verify` again. Do not create these files with `echo`; its trailing newline becomes part of the credential.

**Subnet route works at home, breaks at a cafe.** Subnet collision — the cafe's network uses the same range you advertised, and the local route wins. This is why `linux.env.example` suggests `10.73.42.0/24` rather than `192.168.1.0/24`. Renumbering later is annoying; do it before you have static leases.

**Tailscale silently stopped working after months.** Node key expiry. Disable it on the node in the admin console.

## Linux service and reboot recovery

After completing and verifying the initial Linux deployment, install it as a
systemd-managed service:

```bash
./stack.sh install-service
```

The installer generates a unit for the current checkout and a Docker service
drop-in that requires both the checkout/config path and `DATA_ROOT` to be
mounted before Docker restores containers. It enables normal `systemctl`
lifecycle control without storing the Tailscale auth key in `.env`.

An optional autoheal overlay adds application health checks and restarts only
explicitly labeled unhealthy containers:

```bash
./stack.sh install-service --enable-autoheal
```

Autoheal requires the Docker socket and therefore has host-root-equivalent
access even though the socket is mounted `:ro`. It is disabled by default. Read
[the Linux systemd and autoheal guide](docs/LINUX_SYSTEMD_SERVICE.md) for the
threat model, custom paths, reboot test, NAS power recovery, troubleshooting,
and uninstall steps.

## Legal

This is general-purpose automation. It searches indexes, talks to a download client, renames files, and serves a library. There is nothing infringing about any of that, and there are entirely legitimate uses: organising your own disc rips, managing public-domain and Creative Commons material, keeping self-produced media sorted.

What you point the indexers at is your responsibility. This repo ships an editable `indexers.example.json` with example public indexer definitions and can import the enabled entries into Prowlarr; review and change that file for your own lawful use before importing it. Check the law where you live.