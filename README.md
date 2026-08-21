# edge-bootstrap

Installs and configures a Remnawave node. On a bare server it installs everything
itself; on an existing one it brings the node up to the same state.

```bash
bash node-setup.sh [domain] [--secret-key <key>] [--email <addr>] [--panel-ip <IP>]
                            [--force-cert | --keep-certs] [--new-site] [--brand <name>]
                            [--cert-mode http|dns] [--gcore-token <t>] [--apex <zone>]
                            [--cert-bundle <file>]
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
rr cert-export        # pack the certificate for the other nodes
```

It re-downloads the current version rather than copying itself, and syntax-checks the
download before replacing the command, so a truncated fetch cannot leave a broken `rr`
behind.

If another installer already claims `rr` as a shell alias, that alias wins over `PATH`
and typing `rr` runs the other tool. The script reads the shell rc files to detect this
— aliases are invisible from a non-interactive shell — and prints the full path plus
the command to find the alias, rather than claiming an install that does not work.

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
6. **Handles the certificate** — per-node, or one wildcard for the whole fleet so
   node hostnames stay out of the Certificate Transparency logs. See below.
7. **Generates keys** and writes a ready-to-paste config profile plus host values to
   `/root/<domain>-panel.txt`. The XHTTP `User-Agent` is emitted as an Xray keyword
   (`chrome`/`firefox`/`safari`/`edge`), which the core expands into a full matching
   header set, and it is read from the same variable as the REALITY fingerprint so the
   two cannot disagree.

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

Two ways to get one, and the choice is about Certificate Transparency rather than
convenience.

With neither flag given and a terminal present, the script asks which of the two to
use instead of defaulting quietly — the node looks identical either way, so the
consequence would otherwise never surface. A stored Gcore token is reused on re-runs.

### `--cert-mode http` (default)

`certbot --standalone`, one certificate per node, named after the node. Nothing to
configure and nothing to distribute.

The cost is that **every issuance publishes the node's hostname**. CT logs are public
and permanent, so one query for `%.example.com` on crt.sh returns the fleet — every
node, plus whatever else lives under that apex — without a single packet sent to any
of them. Per-node masquerade sites do not help against this; there is nothing to
correlate when the list is handed over on request.

### `--cert-mode dns`

One wildcard for `*.<apex>`, shared by every node. CT then shows the wildcard and
nothing else, and node hostnames stop being enumerable.

Validation is DNS-01 through the Gcore API, so the apex zone has to be hosted there.
The token comes from `--gcore-token` or `GCORE_API_TOKEN` and is stored in
`/opt/remnanode/.gcore-token` — renewal runs from a systemd timer that carries none
of the invoking shell's environment, so a token that only ever lived in a variable
would work once and fail sixty days later.

The apex is guessed by dropping the first label. Pass `--apex` when that guess cannot
work, such as under a multi-part public suffix.

### One issues, the rest import

When a node has no certificate yet and nothing was passed on the command line, setup
asks which of the two it should do, and the default is import. Issuing is correct for
the first node and wasteful for every other one, and nothing on a node can see whether
another already holds the wildcard — so the question goes to the operator instead of
being guessed.

Let's Encrypt allows **five identical certificates per week**, which is fewer than a
fleet of any size, so the nodes cannot each request the same wildcard. Issue once:

```bash
rr node-a.example.com --cert-mode dns --gcore-token <token>
rr cert-export
```

Copy the bundle to each remaining node and install it there:

```bash
rr node-b.example.com --cert-mode dns --cert-bundle /root/example.com-cert.tgz
```

An imported bundle carries no renewal configuration, so certbot leaves it alone and
nothing on that node will try to renew it. Renewal stays on the issuing host; export
and import again before expiry. The script says so on every run rather than letting
it be a surprise.

### Reuse, force, and the rate limit

A certificate already present with more than seven days of life and a matching name is
reused; reissuing for its own sake burns quota. `--force-cert` drops it and issues a
new one — for a broken certificate, not merely an old one. Certificates belonging to
other domains are deleted first, since a node serves exactly one; `--keep-certs` skips
that.

Hitting the five-per-week ceiling has no remedy but waiting, which is the reason the
default path reuses rather than replaces.

Registration falls back to `--register-unsafely-without-email` unless `--email` is
given. Without an address there are no expiry reminders, which matters little while
renewal is automated and verified on every run.

## Panel IP

Read automatically from the existing ufw rule on `NODE_PORT`, which the stock installer
already creates. Override with the `PANEL_IP` environment variable or `--panel-ip`. If none of those
yields an address, the script asks for it.

## Certificate renewal

In `http` mode nginx takes `:80` while the installer usually configures renewal through
`certbot --standalone`, which needs that port exclusively. The script converts renewal to
`webroot` and verifies it with `certbot renew --dry-run`. If the check fails it reverts to
`standalone` and prints a warning — a silent failure here would only surface when the
certificate expires.

In `dns` mode nothing competes for `:80`. A dry run is deliberately **not** performed:
it would drive two live challenges through the Gcore API and wait on public DNS for
both, on every run. The script checks that the hook and the token are in place instead,
which is what renewal actually depends on.

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
