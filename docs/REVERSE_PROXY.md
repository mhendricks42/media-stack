# Private HTTPS reverse proxy

The optional Caddy overlay gives every browser-facing service a stable HTTPS
hostname while preserving Docker service names for internal traffic. It is
enabled by the checked-in environment templates through the `proxy` Compose
profile.

## Network model

Caddy is the only new ingress service. It joins the existing `medianet` bridge
and forwards requests directly to Compose service names. qBittorrent shares
Gluetun's network namespace, so its upstream is deliberately
`http://gluetun:8080`, not `qbittorrent:8080`.

The initial migration keeps all existing host-port bindings. This provides a
rollback path but means the applications remain reachable directly over HTTP.
Removing those bindings is a separate hardening decision after every client and
integration has moved to the proxy.

## Deploy

1. Existing deployments must add the overlay and profile to their current
   `.env`; copying the new template would overwrite local settings:

   ```dotenv
   COMPOSE_FILE=docker-compose.yml:compose/linux.yml:compose/secrets.yml:compose/proxy.yml
   COMPOSE_PROFILES=proxy
   ```

   Preserve any existing overlays in `COMPOSE_FILE` and any existing profiles
   as a comma-separated list, such as `COMPOSE_PROFILES=proxy,tailscale`.

2. Confirm ports 80 and 443 are not already owned by UGOS or another process:

   ```bash
   sudo ss -ltnp | grep -E ':(80|443)\s'
   ```

3. Choose the private DNS suffix in `.env`:

   ```dotenv
   PROXY_DOMAIN=media.home.arpa
   PROXY_TLS_POLICY=./proxy/tls/internal.caddy
   ```

4. Create local DNS records pointing at the NAS LAN address. A wildcard is
   simplest:

   ```text
   *.media.home.arpa  A  192.168.1.10
   ```

   If the DNS server has no wildcard support, create records for `qbittorrent`,
   `sabnzbd`, `prowlarr`, `sonarr`, `radarr`, `bazarr`, `jellyfin`, `ersatztv`,
   and `seerr`.

5. Render and start:

   ```bash
   ./stack.sh config
   ./stack.sh up
   ./stack.sh proxy-check
   ./stack.sh proxy-ca
   ```

   `proxy-check` verifies the Caddy health status, private certificate, hostname
   routing, and every upstream connection. `proxy-ca` exports the root
   certificate to `config/caddy/pki/root.crt`.

6. Install `config/caddy/pki/root.crt` as a trusted root CA on each client.
   Import it into the operating-system trust store, not as a client certificate.
   Treat the Caddy data volume as sensitive: it contains the root CA private key.
   Never copy or commit files from that volume.

7. Open `https://sonarr.media.home.arpa`, then create one password-manager entry
   per hostname and enable exact-website matching.

## External ACME CA scaffold

The default `proxy/tls/internal.caddy` policy uses Caddy's private CA. To move to
an ACME-compatible CA, set:

```dotenv
PROXY_TLS_POLICY=./proxy/tls/acme.caddy.example
ACME_EMAIL=operator@example.com
ACME_CA_DIRECTORY=https://acme.example.com/directory
```

Then recreate Caddy:

```bash
./stack.sh config
docker compose up -d --force-recreate caddy
./stack.sh proxy-check
```

Public certificate authorities will not issue for `home.arpa`. Use a domain you
control and change `PROXY_DOMAIN` before selecting a public CA. The stock image
can use HTTP-01 or TLS-ALPN-01, both of which normally require inbound Internet
reachability. Do not expose the media-management applications merely to obtain a
certificate. Prefer split DNS with a DNS-01-capable custom Caddy build, or use a
private ACME CA reachable only from the LAN or tailnet.

## Security decisions still open

- **Direct HTTP ports:** retained for migration. Once proxy access is proven,
  move or remove application `ports:` mappings so Caddy is the only LAN ingress.
- **Private CA distribution:** every browser, phone, and TV must trust the root.
  Devices that cannot install it may need a public certificate on a privately
  resolved domain.
- **Remote access boundary:** no router port forwarding is added. Keep access on
  the LAN or Tailscale unless a separate threat model approves public ingress.
- **Caddy state backup:** back up the `caddy_data` volume securely if preserving
  the private CA identity matters. Losing it requires trusting a new root on all
  clients.
- **Compromise impact:** Caddy can reach every HTTP service on `medianet`.
  Its root filesystem is read-only, Linux capabilities are reduced to
  `NET_BIND_SERVICE`, and it has no Docker socket, but a proxy compromise still
  creates a path to application login surfaces.
