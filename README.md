# edge-bootstrap

Post-install setup for a Remnawave node. Run it **after** the stock installer —
it does not replace it.

```bash
bash node-setup.sh <domain> [--panel-ip <IP>]
```

## Why

The stock installer brings a node up, but leaves it in a state that needs manual
follow-up: the image floats on `latest`, nginx ships without hardening, more ports
are exposed than necessary, and the config profile has to be assembled by hand.
This script closes all of that in one pass.

## What it does

1. **Pins the node image** to a known-good tag and verifies the core version after start.
   `latest` can pull a newer core where XHTTP over REALITY is broken
   ([XTLS/Xray-core#6482](https://github.com/XTLS/Xray-core/issues/6482)) — the node
   starts fine, but two inbounds silently do nothing.
2. **Fixes docker-compose** — adds the `/etc/letsencrypt` mount to `remnanode`.
   Without it Hysteria2 cannot read the certificate.
3. **Writes a hardened nginx config**: `server_tokens off`, 404 on common scanner paths,
   SPA fallback, `access_log off` (the access log is mostly scanner noise and can grow
   to hundreds of megabytes per container).
4. **Installs a small static site**, deterministically different per domain.
5. **Configures the firewall**: only `80/tcp`, `443/tcp` and `443/udp` are exposed.
   `NODE_PORT` is restricted to the panel IP, and any pre-existing wide-open rule for it
   is removed.
6. **Generates keys** and writes a ready-to-paste config profile plus host values to
   `/root/<domain>-panel.txt`.

## Inbounds

`XHTTP-REALITY` on 443/tcp and `Hysteria2` on 443/udp.

VLESS-PQ and HTTPUpgrade are intentionally omitted. Each cost an extra host entry per
node, and PQ on a secondary port served a byte-identical site and certificate to 443 —
the same content on two ports is an odd thing to expose. With those gone the node
listens on 80 and 443 only: 80 redirects to HTTPS and serves the ACME challenge,
443/tcp serves the site, 443/udp answers nothing unless it recognises the traffic.

## Panel IP

Read automatically from the existing ufw rule on `NODE_PORT`, which the stock installer
already creates. Override with the `PANEL_IP` environment variable or `--panel-ip`.
If none of the three yields an address, the script stops instead of guessing.

## Certificate renewal

nginx takes `:80`, while the installer usually configures renewal through
`certbot --standalone`, which needs that port exclusively. The script converts renewal
to `webroot` and verifies it with `certbot renew --dry-run`. If the check fails it
reverts to `standalone` and prints a warning — a silent failure here would only surface
when the certificate expires.

## Re-runs and rollback

Safe to re-run. Backups are written before anything is overwritten:
`docker-compose.yml.bak-<date>`, `nginx.conf.bak-<date>`, `<domain>.conf.bak-<date>`.

⚠️ Keys are regenerated on every run. On a node that already has clients this will
disconnect them — the script is meant for initial setup. When moving an existing node
to a new host, reuse the keys from the panel instead.

## Requirements

Ubuntu or Debian, root, docker with compose v2, a certificate already issued for the
domain, and a node installed in `/opt/remnanode`.
