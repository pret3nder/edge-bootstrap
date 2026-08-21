# edge-bootstrap

Installs and configures a Remnawave node. On a bare server it installs everything
itself; on an existing one it brings the node up to the same state.

```bash
bash node-setup.sh [domain] [--secret-key <key>] [--email <addr>] [--panel-ip <IP>]
                            [--force-cert | --keep-certs] [--new-site] [--brand <name>]
```

Anything not supplied on the command line is asked for interactively, so the usual
invocation is just:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/pret3nder/edge-bootstrap/master/node-setup.sh)
```

Prompts read from `/dev/tty`, which keeps them working under both `bash <(curl ...)` and
`curl ... | bash`. Where there is no controlling terminal — cron, CI — the script fails
with a message naming the missing value instead of hanging.

After a successful run the script installs itself as `rr`, so later runs on that host are
just:

```bash
rr                    # menu
rr node.example.com   # set up or reconfigure
rr check              # health check, read-only
rr panel              # print the saved panel values again
```

It re-downloads the current version rather than copying itself, and syntax-checks the
download before replacing the command, so a truncated fetch cannot leave a broken `rr`
behind.

## Health check

`rr check` re-tests every failure this tool has met in the field, in one read-only pass:
container state, core version against the expected one, whether nginx is serving the file
on disk or a stale inode, certificate expiry and renewal method, whether the certificate
mount still names the domain the node serves, firewall state and exposed ports, what is
actually listening locally, and the presence of the static site the SPA fallback needs.

It changes nothing, so it is safe on a live node.

## Bare server

With no node in `/opt/remnanode` the script installs one: docker and compose v2,
certbot, ufw, then a `docker-compose.yml` pinned to a known-good image with the
certificate mounted into `remnanode` from the start. It asks for the SECRET_KEY from
the node card in the panel, which is the one value nothing local can derive.

From there the run continues exactly as it would on an existing node, so a fresh
server reaches a configured node in a single command.

## Why pin the version

A floating tag has twice pulled a core where XHTTP over REALITY is broken
([XTLS/Xray-core#6482](https://github.com/XTLS/Xray-core/issues/6482)). The node starts,
the panel shows it connected, and two inbounds quietly do nothing — which reads as a
network problem and is debugged as one.

The exact number matters less than the pinning. `NODE_IMAGE` and `XRAY_EXPECT` at the
top of the script are simply the pair currently known to work; move them together once
a newer release is verified.

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
4. **Installs a static site**, generated from a per-node seed. Not filled into a
   template — generated: class names are drawn from a shared pool without
   replacement, the accent is computed in HSL rather than picked from a list, and
   type scale, spacing, page width, font stack, section counts and copy all come
   from separate bytes of the same seed. See below.
5. **Configures the firewall**: only `80/tcp`, `443/tcp` and `443/udp` are exposed.
   `NODE_PORT` is restricted to the panel IP, and any pre-existing wide-open rule for it
   is removed.
6. **Handles the certificate** — see below.
7. **Generates keys** and writes a ready-to-paste config profile plus host values to
   `/root/<domain>-panel.txt`.

## Masquerade site

The seed lives in `/opt/remnanode/.site-seed` and is random, not derived from the
domain. Deriving it from the domain is the obvious approach and it is the wrong one:
it caps the fleet at the size of the word lists, so nodes begin repeating each other
as the fleet grows, which is the failure this is meant to prevent. A stored seed keeps
re-runs reproducible — the same node rebuilds the same site — without that ceiling.

Over 200 generated sites, all 200 pages and all 200 stylesheets were distinct. Names
collided three times in 200; the name space is smaller than the page space because a
name has to stay pronounceable. At fleet sizes in the tens that is a few percent
chance of one repeat, so it is worth a look rather than an assumption.

- `--new-site` rerolls the seed and rebuilds the page.
- `--brand "Name"` sets the name outright, which is the guarantee when one is wanted.

The name in use is recorded in `/root/<domain>-panel.txt`, so a fleet can be checked
without visiting each site.

## Inbounds

`XHTTP-REALITY` on 443/tcp and `Hysteria2` on 443/udp.

VLESS-PQ and HTTPUpgrade are intentionally omitted. Each cost an extra host entry per
node, and PQ on a secondary port served a byte-identical site and certificate to 443 —
the same content on two ports is an odd thing to expose. With those gone the node
listens on 80 and 443 only: 80 redirects to HTTPS and serves the ACME challenge,
443/tcp serves the site, 443/udp answers nothing unless it recognises the traffic.

## Certificate

The script issues the certificate itself, so a node can be pointed at a new domain in
a single run. Order of operations:

- certificates belonging to **other** domains are deleted first. A node serves exactly
  one domain, and leftovers from a previous one only get in the way. `--keep-certs`
  skips this.
- if a valid certificate for the target domain is already present — more than seven days
  of life left and a matching SAN — it is **reused**. Reissuing for its own sake burns
  quota.
- otherwise one is issued with `certbot --standalone`. The nginx container is stopped for
  the duration, since that method needs port 80 to itself.

`--force-cert` drops the current certificate and issues a new one. Use it when the
existing certificate is broken, not merely old.

Let's Encrypt allows **five certificates per exact domain per week**. Forcing a reissue
repeatedly on the same domain will hit that ceiling, and the only remedy is to wait it
out — which is precisely why the default path reuses a valid certificate rather than
replacing it.

Registration falls back to `--register-unsafely-without-email` unless `--email` is given.
Without an address there are no expiry reminders, which matters little here because
renewal is automated and verified on every run.

## Panel IP

Read automatically from the existing ufw rule on `NODE_PORT`, which the stock installer
already creates. Override with the `PANEL_IP` environment variable or `--panel-ip`. If none of those
yields an address, the script asks for it.

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
disconnect them — the script is meant for initial setup or for repointing a node at a
new domain. When moving an existing node to a new host while keeping its clients, reuse
the keys from the panel instead.

## Requirements

Ubuntu or Debian, root, docker with compose v2, certbot, and a node installed in
`/opt/remnanode`. The domain must already resolve to the host, and port 80 must be
reachable from the internet for issuance to succeed.
