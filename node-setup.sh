#!/usr/bin/env bash
# node-setup.sh - post-install setup for a Remnawave node. Run after the stock installer.
#
#   bash node-setup.sh [domain] [options]
#
# Anything not supplied on the command line is asked for interactively;
# with no controlling terminal the script fails with a clear message instead.
#
# Options:
#   --panel-ip <IP>   panel address for the NODE_PORT rule (auto-detected by default)
#   --email <addr>    e-mail for the Let's Encrypt account (first registration only)
#   --force-cert      drop the current certificate and issue a fresh one
#   --keep-certs      keep certificates belonging to other domains
#
# The panel IP is read from the existing ufw rule on NODE_PORT, and asked for if absent.
#
# What it does:
#   1. pins remnawave/node to a known-good tag and verifies the running core version
#   2. mounts /etc/letsencrypt into remnanode (Hysteria2 reads the certificate directly)
#   3. writes a hardened nginx config (server_tokens off, probe-404, SPA fallback, access_log off)
#   4. installs a small static site, deterministically different per domain
#   5. firewall: only 80 and 443 tcp+udp exposed; NODE_PORT restricted to the panel IP
#   6. issues the certificate if missing and clears ones left from a previous domain
#   7. generates keys and writes a ready-to-paste config profile and host values to a file
#
# Inbounds: XHTTP-REALITY (443/tcp) and Hysteria2 (443/udp).
# VLESS-PQ and HTTPUpgrade are intentionally omitted: extra listening ports add no value here.
set -euo pipefail

NODE_IMAGE="remnawave/node:2.8.0"     # core version verified after start
XRAY_EXPECT="26.6.27"
PANEL_IP="${PANEL_IP:-}"          # see detect_panel_ip
DIR="/opt/remnanode"

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }
die(){ red "ERROR: $*"; exit 1; }

# Prompting reads from /dev/tty rather than stdin, so it works both with
#   bash <(curl -Ls URL)   and   curl -Ls URL | bash
# In a context with no controlling terminal it degrades to a clear error.
can_ask(){ : >/dev/tty 2>/dev/null; }

# ask <prompt> <varname> [validating-regex] [default]
ask() {
  local prompt="$1" var="$2" re="${3:-.}" def="${4:-}" answer
  can_ask || return 1
  while :; do
    if [ -n "$def" ]; then printf '\033[33m%s\033[0m [%s]: ' "$prompt" "$def" >/dev/tty
    else                   printf '\033[33m%s\033[0m: '      "$prompt"       >/dev/tty; fi
    read -r answer </dev/tty || return 1
    [ -z "$answer" ] && answer="$def"
    if [ -n "$answer" ] && printf '%s' "$answer" | grep -qE "$re"; then
      printf -v "$var" '%s' "$answer"
      return 0
    fi
    red "  invalid value, try again" >/dev/tty
  done
}

# ---------------------------------------------------------------------------
# Health check. Every item here is something that has silently broken a node
# before, so the point is to surface them in one pass instead of discovering
# them when users complain.
# Read-only: it never changes anything.
# ---------------------------------------------------------------------------
cmd_check() {
  local d="${1:-}" fails=0 warns=0 v st out days

  # Domain: take the argument, else read it back from the running nginx config.
  if [ -z "$d" ] && [ -f "$DIR/nginx.conf" ]; then
    d=$(grep -m1 -oE 'server_name[[:space:]]+[^;]+' "$DIR/nginx.conf" 2>/dev/null | awk '{print $2}' || true)
  fi

  echo
  ylw "=== health check${d:+ | $d} ==="

  # --- containers -----------------------------------------------------------
  for c in remnanode remnawave-nginx; do
    st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
    if [ "$st" = "running" ]; then
      grn "  container $c: running"
    else
      red "  container $c: $st"
      [ "$st" = "restarting" ] && docker logs --tail 3 "$c" 2>&1 | sed 's/^/      /'
      fails=$((fails + 1))
    fi
  done

  # --- core version ---------------------------------------------------------
  # A floating tag has twice pulled a core where XHTTP over REALITY is broken:
  # the node starts and looks healthy while two inbounds quietly do nothing.
  v=$(docker logs remnanode 2>&1 | grep -a -m1 "Xray version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  if [ "$v" = "$XRAY_EXPECT" ]; then
    grn "  core: $v"
  else
    red "  core: ${v:-unknown}, expected $XRAY_EXPECT"
    fails=$((fails + 1))
  fi
  if grep -q "image: remnawave/node:latest" "$DIR/docker-compose.yml" 2>/dev/null; then
    ylw "  image: pinned to latest - the next pull can change the core silently"
    warns=$((warns + 1))
  fi

  # --- nginx is serving the file on disk ------------------------------------
  # The config is a file-bound mount, so docker holds it by inode. An upload that
  # replaces the file leaves the container reading the old one, and a reload
  # re-reads that same stale inode without complaining.
  if docker exec remnawave-nginx grep -q server_tokens /etc/nginx/conf.d/default.conf 2>/dev/null; then
    grn "  nginx: serving the current config"
  else
    red "  nginx: container is not serving the hardened config"
    red "         fix: docker compose up -d --force-recreate remnawave-nginx"
    fails=$((fails + 1))
  fi

  # --- certificate ----------------------------------------------------------
  if [ -n "$d" ] && [ -f "/etc/letsencrypt/live/$d/fullchain.pem" ]; then
    days=$(( ( $(date -d "$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$d/fullchain.pem" 2>/dev/null | cut -d= -f2)" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
    if [ "$days" -gt 20 ]; then grn "  certificate: valid, $days days left"
    elif [ "$days" -gt 0 ]; then ylw "  certificate: only $days days left"; warns=$((warns + 1))
    else red "  certificate: expired or unreadable"; fails=$((fails + 1)); fi
  else
    red "  certificate: none for ${d:-this node}"
    fails=$((fails + 1))
  fi

  # Renewal through standalone cannot work while nginx holds :80.
  if [ -n "$d" ] && [ -f "/etc/letsencrypt/renewal/$d.conf" ]; then
    if grep -q '^authenticator[[:space:]]*=[[:space:]]*standalone' "/etc/letsencrypt/renewal/$d.conf"; then
      red "  renewal: standalone, which needs port 80 that nginx now holds"
      fails=$((fails + 1))
    else
      grn "  renewal: webroot"
    fi
  fi

  # The mount names a fixed path; repointing the node without updating it leaves
  # nginx loading a certificate that is no longer there.
  out=$(grep -oE '/etc/letsencrypt/live/[^/]+/fullchain\.pem' "$DIR/docker-compose.yml" 2>/dev/null | head -1 | cut -d/ -f5 || true)
  if [ -n "$out" ] && [ -n "$d" ] && [ "$out" != "$d" ]; then
    red "  compose: certificate mount points at $out, node serves $d"
    fails=$((fails + 1))
  fi
  if ! grep -q '/etc/letsencrypt:/etc/letsencrypt' "$DIR/docker-compose.yml" 2>/dev/null; then
    red "  compose: /etc/letsencrypt is not mounted into remnanode - Hysteria2 cannot read the certificate"
    fails=$((fails + 1))
  fi

  # --- firewall -------------------------------------------------------------
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    grn "  firewall: active"
    for p in 2053 8443; do
      if ufw status 2>/dev/null | grep -qE "(^|[^0-9])$p([^0-9]|\$)"; then
        ylw "  firewall: a rule for $p is still present"
        warns=$((warns + 1))
      fi
    done
    if ufw status 2>/dev/null | grep -qE '2222.*(Anywhere|0\.0\.0\.0)'; then
      red "  firewall: NODE_PORT is open to the internet - it identifies the node to anyone scanning"
      fails=$((fails + 1))
    fi
  else
    red "  firewall: inactive - rules may exist but nothing is enforced"
    fails=$((fails + 1))
  fi

  # --- what is actually listening ------------------------------------------
  # More trustworthy than an external scan: some providers accept TCP at their
  # edge on every port, which makes a remote probe look wrong.
  out=$(ss -ltn 2>/dev/null | awk 'NR>1 {n=split($4,a,":"); print a[n]}' | sort -un | tr '\n' ' ' || true)
  echo "  listening tcp: ${out:-none}"
  for p in 2053 8443; do
    case " $out " in *" $p "*) ylw "  listening: $p is still bound - the panel profile still has that inbound"; warns=$((warns + 1)) ;; esac
  done
  case " $out " in *" 2222 "*) grn "  node port 2222: listening" ;; *) red "  node port 2222: not listening - the panel cannot reach this node"; fails=$((fails + 1)) ;; esac

  # --- site -----------------------------------------------------------------
  if [ -s /var/www/html/index.html ]; then
    grn "  static site: present ($(grep -m1 -oE '<title>[^<]*' /var/www/html/index.html 2>/dev/null | sed 's/<title>//' || echo untitled))"
  else
    red "  static site: missing - the SPA fallback will loop and return 500 on everything"
    fails=$((fails + 1))
  fi

  echo
  if [ "$fails" -gt 0 ]; then
    red "  $fails problem(s), $warns warning(s)"
  elif [ "$warns" -gt 0 ]; then
    ylw "  no problems, $warns warning(s)"
  else
    grn "  all checks passed"
  fi
  return 0
}

# Re-print the values a setup run produced. They are needed again whenever the
# node is re-added in the panel, and the file is easy to lose track of.
cmd_panel() {
  local d="${1:-}" f
  if [ -z "$d" ] && [ -f "$DIR/nginx.conf" ]; then
    d=$(grep -m1 -oE 'server_name[[:space:]]+[^;]+' "$DIR/nginx.conf" 2>/dev/null | awk '{print $2}' || true)
  fi
  f="/root/${d}-panel.txt"
  if [ -n "$d" ] && [ -f "$f" ]; then
    cat "$f"
  else
    red "No saved panel values${d:+ for $d}."
    ylw "Run a setup pass to regenerate them - note that this issues new keys"
    ylw "and disconnects existing clients of this node."
    return 1
  fi
}

menu() {
  can_ask || return 1
  local choice
  while :; do
    printf '\n\033[33m  edge-bootstrap\033[0m\n' >/dev/tty
    printf '    1) set up / reconfigure this node\n' >/dev/tty
    printf '    2) health check\n' >/dev/tty
    printf '    3) show panel values\n' >/dev/tty
    printf '    0) exit\n' >/dev/tty
    printf '  choice: ' >/dev/tty
    read -r choice </dev/tty || return 1
    case "$choice" in
      1) ACTION=setup; return 0 ;;
      2) ACTION=check; return 0 ;;
      3) ACTION=panel; return 0 ;;
      0) exit 0 ;;
      *) red "  pick 0-3" >/dev/tty ;;
    esac
  done
}

RE_DOMAIN='^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$'
RE_IP='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

# First positional argument is either a sub-command or the domain.
ACTION=setup
case "${1:-}" in
  check|panel|setup) ACTION="$1"; shift ;;
  menu)              ACTION=menu; shift ;;
esac

DOMAIN="${1:-}"
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    --panel-ip)   shift; PANEL_IP="${1:-}" ;;
    --email)      shift; EMAIL="${1:-}" ;;
    --force-cert) FORCE_CERT=1 ;;
    --keep-certs) KEEP_CERTS=1 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

# Panel IP: --panel-ip flag -> PANEL_IP env var ->
# existing firewall rule on NODE_PORT (created by the stock installer).
detect_panel_ip() {
  [ -n "${PANEL_IP:-}" ] && return 0
  command -v ufw >/dev/null 2>&1 || return 1
  PANEL_IP=$(ufw status 2>/dev/null | awk '
    /2222/ {
      for (i = 1; i <= NF; i++)
        if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $i != "0.0.0.0") { print $i; exit }
    }' || true)
  [ -n "$PANEL_IP" ]
}

[ "$(id -u)" = "0" ] || die "must run as root"
[ -d "$DIR" ] || die "$DIR not found - run the stock installer first"
command -v docker >/dev/null || die "docker is not installed"

# With no arguments at all and a terminal available, offer the menu.
if [ "$ACTION" = "setup" ] && [ -z "$DOMAIN" ] && can_ask && [ -f "$DIR/nginx.conf" ]; then
  ACTION=menu
fi
[ "$ACTION" = "menu" ] && { menu || die "no terminal for the menu"; }

case "$ACTION" in
  check) cmd_check "$DOMAIN"; exit 0 ;;
  panel) cmd_panel "$DOMAIN"; exit $? ;;
esac

# ---- from here on: setup ----
if [ -z "$DOMAIN" ]; then
  ask "Node domain (selfsteal domain used during installation)" DOMAIN "$RE_DOMAIN"     || die "domain required: bash node-setup.sh node.example.com"
fi
printf "%s" "$DOMAIN" | grep -qE "$RE_DOMAIN" || die "not a valid domain: $DOMAIN"
[ -f "$DIR/docker-compose.yml" ] || die "missing $DIR/docker-compose.yml"
command -v certbot >/dev/null || die "certbot is not installed"

if detect_panel_ip; then
  grn "  panel IP taken from the existing firewall rule: $PANEL_IP"
else
  ask "Panel IP address (the one the node connects back to)" PANEL_IP "$RE_IP"     || die "could not determine the panel IP.
  Via env:  PANEL_IP=1.2.3.4 bash node-setup.sh $DOMAIN
  Via flag: bash node-setup.sh $DOMAIN --panel-ip 1.2.3.4"
fi

STAMP="$(date +%F-%H%M)"
echo
ylw "=== $DOMAIN | image $NODE_IMAGE ==="

# ---------- 1. docker-compose ----------
cp "$DIR/docker-compose.yml" "$DIR/docker-compose.yml.bak-$STAMP"
sed -i -E "s|image:[[:space:]]*remnawave/node:[^[:space:]]+|image: $NODE_IMAGE|" "$DIR/docker-compose.yml"
grep -q "image: $NODE_IMAGE" "$DIR/docker-compose.yml" || die "failed to pin the image"

if ! grep -q '/etc/letsencrypt:/etc/letsencrypt' "$DIR/docker-compose.yml"; then
  awk '
    /^[[:space:]]*remnanode:/ { innode=1 }
    innode && /\/dev\/shm:\/dev\/shm:rw/ && !done {
      match($0, /^[[:space:]]*/)
      printf "%s- /etc/letsencrypt:/etc/letsencrypt:ro\n", substr($0, 1, RLENGTH)
      done=1
    }
    { print }
  ' "$DIR/docker-compose.yml" > "$DIR/.dc.tmp" && mv "$DIR/.dc.tmp" "$DIR/docker-compose.yml"
fi
if grep -q '/etc/letsencrypt:/etc/letsencrypt' "$DIR/docker-compose.yml"; then
  grn "  compose: image pinned, certificate mount present"
else
  ylw "  compose: could not add the /etc/letsencrypt mount - check manually"
fi

# nginx mounts the certificate by explicit path, so repointing the node at another
# domain means rewriting those two lines. Left alone, nginx keeps loading a path that
# no longer exists, docker helpfully creates a directory there, and the container
# ends up in a restart loop.
OLDCERT=$(grep -oE '/etc/letsencrypt/live/[^/]+/fullchain\.pem' "$DIR/docker-compose.yml" | head -1 | cut -d/ -f5 || true)
if [ -n "$OLDCERT" ] && [ "$OLDCERT" != "$DOMAIN" ]; then
  sed -i -E "s|/etc/letsencrypt/live/[^/]+/(fullchain\|privkey)\.pem:/etc/nginx/ssl/[^/]+/(fullchain\|privkey)\.pem|/etc/letsencrypt/live/$DOMAIN/\1.pem:/etc/nginx/ssl/$DOMAIN/\2.pem|g" \
      "$DIR/docker-compose.yml"
  grn "  compose: certificate mounts repointed $OLDCERT -> $DOMAIN"
fi

# Clear placeholders docker created where a certificate file was expected but missing.
for p in /etc/letsencrypt/live/*/fullchain.pem /etc/letsencrypt/live/*/privkey.pem; do
  [ -d "$p" ] || continue
  ylw "  cleanup: removing directory docker left at $p"
  rm -rf "$p"
done

# ---------- 2. hardened nginx ----------
[ -f "$DIR/nginx.conf" ] && cp "$DIR/nginx.conf" "$DIR/nginx.conf.bak-$STAMP"
{
  echo 'server_names_hash_bucket_size 64;'
  echo 'server_tokens off;'
  echo ''
  echo 'ssl_protocols TLSv1.2 TLSv1.3;'
  echo 'ssl_ecdh_curve X25519:prime256v1:secp384r1;'
  echo 'ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;'
  echo 'ssl_prefer_server_ciphers on;'
  echo 'ssl_session_timeout 1d;'
  echo 'ssl_session_cache shared:MozSSL:10m;'
  echo 'ssl_session_tickets off;'
  echo 'access_log off;'
  echo ''
  echo 'server {'
  echo '    listen 80;'
  echo "    server_name $DOMAIN;"
  echo '    location /.well-known/acme-challenge/ { root /var/www/html; }'
  echo '    location / { return 301 https://$host$request_uri; }'
  echo '}'
  echo ''

  echo 'server {'
  echo "    server_name $DOMAIN;"
  echo '    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;'
  echo '    http2 on;'
  echo ''
  echo "    ssl_certificate         \"/etc/nginx/ssl/$DOMAIN/fullchain.pem\";"
  echo "    ssl_certificate_key     \"/etc/nginx/ssl/$DOMAIN/privkey.pem\";"
  echo "    ssl_trusted_certificate \"/etc/nginx/ssl/$DOMAIN/fullchain.pem\";"
  echo ''
  echo '    root   /var/www/html;'
  echo '    index  index.html;'
  echo ''
  echo '    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;'
  echo '    add_header X-Content-Type-Options    "nosniff" always;'
  echo '    add_header X-Frame-Options           "SAMEORIGIN" always;'
  echo ''
  echo '    location ~* ^/(\.env|\.git|\.aws|wp-login\.php|wp-admin|xmlrpc\.php|phpmyadmin|administrator|owa|autodiscover) {'
  echo '        return 404;'
  echo '    }'
  echo '    location ~* \.(ico|png|svg|jpe?g|gif|webp|css|js|mjs|map|txt|xml|json|webmanifest|woff2?|ttf)$ {'
  echo '        try_files $uri =404;'
  echo '    }'
  echo '    location / {'
  echo '        try_files $uri $uri/ /index.html;'
  echo '    }'
  echo '}'
  echo ''
  echo 'server {'
  echo '    listen unix:/dev/shm/nginx.sock ssl proxy_protocol default_server;'
  echo '    server_name _;'
  echo '    ssl_reject_handshake on;'
  echo '    return 444;'
  echo '}'
} > "$DIR/nginx.conf"
grn "  nginx: hardened config written"

# ---------- 3. static site ----------
# The page has to differ per node: one identical document served from a dozen
# addresses is itself something to correlate on. Brand, accent colour and layout
# are all derived from the domain hash, so a node regenerates the same site every
# time while no two nodes share one.
mkdir -p /var/www/html
H=$(printf '%s' "$DOMAIN" | md5sum | tr -dc '0-9' | cut -c1-9)
[ -z "$H" ] && H=123456789
BRANDS=("Northwind|Infrastructure notes and tooling|#3b6ea5"
        "Kestrel|Small tools, done properly|#2f7a5b"
        "Basalt|Systems engineering studio|#8a4b2a"
        "Vellum|Documentation and handbooks|#5a4b8a"
        "Tessera|Data plumbing for small teams|#2b6b7a"
        "Halcyon|Software, unhurried|#2b5a7a"
        "Ridgeway|Practical automation|#7a5a2b"
        "Lumen|Interfaces and prototypes|#7a3f5a"
        "Alder|Scheduling for background work|#4a4a6b"
        "Wren|Field notes on small systems|#3f6b6b"
        "Marlowe|Backend consulting|#6b3f4a"
        "Foundry|Build and release tooling|#556b2f"
        "Cairn|Monitoring without the noise|#2f5b6b"
        "Thicket|Data pipelines, plainly|#6b5a3f"
        "Beacon|Status pages and alerting|#3f4a7a"
        "Quarry|Storage and archival|#6b6b2b")
IDX=$(( 10#${H:0:6} % ${#BRANDS[@]} ))
LAYOUT=$(( 10#${H:6:2} % 4 ))
BN="${BRANDS[$IDX]%%|*}"
REST="${BRANDS[$IDX]#*|}"
BT="${REST%%|*}"
BC="${REST#*|}"
YEAR=$(( 2015 + 10#${H:0:2} % 10 ))
NPOST=$(( 20 + 10#${H:2:2} % 80 ))
NPROJ=$(( 10 + 10#${H:4:2} % 60 ))

{
  echo '<!doctype html><html lang="en"><head><meta charset="utf-8">'
  echo '<meta name="viewport" content="width=device-width,initial-scale=1">'
  echo "<title>$BN &mdash; $BT</title><meta name=\"description\" content=\"$BT\">"
  echo '<style>'
  echo ":root{--a:$BC;--ink:#1c1f23;--m:#5d6672;--l:#e4e7eb;--s:#f6f7f9}"
  echo '*{box-sizing:border-box;margin:0;padding:0}'
  echo 'body{font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:var(--ink);background:#fff}'
  echo 'a{color:var(--a);text-decoration:none}a:hover{text-decoration:underline}'
  echo '.w{max-width:960px;margin:0 auto;padding:0 24px}'
  echo 'header{border-bottom:1px solid var(--l);padding:18px 0}'
  echo '.n{display:flex;align-items:center;justify-content:space-between}'
  echo '.b{font-weight:650;font-size:17px}.b span{color:var(--a)}'
  echo 'nav ul{display:flex;gap:22px;list-style:none;font-size:14px}nav a{color:var(--m)}'
  echo '.h{padding:72px 0 56px;border-bottom:1px solid var(--l)}'
  echo '.h h1{font-size:38px;line-height:1.2;letter-spacing:-.6px;max-width:640px}'
  echo '.h p{color:var(--m);margin-top:16px;max-width:560px}'
  echo '.btn{display:inline-block;margin-top:28px;background:var(--a);color:#fff;padding:10px 18px;border-radius:6px;font-size:14px}'
  echo '.g{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:28px;padding:56px 0}'
  echo '.c h3{font-size:16px;margin-bottom:8px}.c p{color:var(--m);font-size:14px}'
  echo '.st{background:var(--s);border-top:1px solid var(--l);border-bottom:1px solid var(--l);padding:40px 0}'
  echo '.st .w{display:flex;flex-wrap:wrap;gap:40px}'
  echo '.s b{display:block;font-size:24px}.s span{color:var(--m);font-size:13px}'
  echo 'footer{padding:36px 0;color:var(--m);font-size:13px;display:flex;justify-content:space-between;flex-wrap:wrap;gap:12px}'
  echo '@media(max-width:640px){.h h1{font-size:29px}nav ul{display:none}}'
  echo '</style></head><body>'

  case "$LAYOUT" in
    0)  # studio / agency
      echo "<header><div class=\"w n\"><div class=\"b\">$BN<span>.</span></div>"
      echo '<nav><ul><li><a href="/work">Work</a></li><li><a href="/notes">Notes</a></li><li><a href="/about">About</a></li></ul></nav></div></header>'
      echo "<section class=\"h\"><div class=\"w\"><h1>$BT</h1>"
      echo '<p>We design and maintain small, reliable systems &mdash; internal tools, data pipelines and the unglamorous plumbing that keeps them running.</p>'
      echo '<a class="btn" href="/work">See recent work</a></div></section>'
      echo '<div class="w"><div class="g">'
      echo '<div class="c"><h3>Internal tooling</h3><p>Dashboards, admin panels and job runners that teams keep using after launch.</p></div>'
      echo '<div class="c"><h3>Data plumbing</h3><p>Ingest, transform, schedule. Boring on purpose, observable by default.</p></div>'
      echo '<div class="c"><h3>Maintenance</h3><p>Long-term care for systems that outlived the team that wrote them.</p></div>'
      echo '</div></div>'
      echo '<div class="st"><div class="w">'
      echo "<div class=\"s\"><b>$YEAR</b><span>Working since</span></div>"
      echo "<div class=\"s\"><b>$NPROJ</b><span>Projects shipped</span></div>"
      echo '<div class="s"><b>6</b><span>People</span></div>'
      echo '</div></div>'
      echo "<div class=\"w\"><footer><div>&copy; 2026 $BN</div><div><a href=\"/privacy\">Privacy</a> &middot; <a href=\"/contact\">Contact</a></div></footer></div>" ;;
    1)  # small SaaS / API
      echo "<header><div class=\"w n\"><div class=\"b\">$BN<span>/</span>api</div>"
      echo '<nav><ul><li><a href="/docs">Docs</a></li><li><a href="/pricing">Pricing</a></li><li><a href="/changelog">Changelog</a></li></ul></nav></div></header>'
      echo "<section class=\"h\"><div class=\"w\"><h1>$BT</h1>"
      echo '<p>A small HTTP API for queueing and running deferred jobs. No agents, no sidecars &mdash; one endpoint and a token.</p>'
      echo '<a class="btn" href="/docs">Read the docs</a></div></section>'
      echo '<div class="w"><div class="g">'
      echo '<div class="c"><h3>Simple by design</h3><p>One POST creates a job. One GET tells you how it went. That is the whole surface.</p></div>'
      echo '<div class="c"><h3>Retries built in</h3><p>Exponential backoff, dead-letter queue, idempotency keys. Nothing to configure.</p></div>'
      echo '<div class="c"><h3>Observable</h3><p>Structured logs and per-job timing out of the box.</p></div>'
      echo '</div></div>'
      echo '<div class="st"><div class="w">'
      echo "<div class=\"s\"><b>v2.$(( 10#${H:0:1} ))</b><span>Current release</span></div>"
      echo '<div class="s"><b>99.9%</b><span>Target uptime</span></div>'
      echo "<div class=\"s\"><b>&lt;$(( 60 + 10#${H:1:2} % 40 ))ms</b><span>Median enqueue</span></div>"
      echo '</div></div>'
      echo "<div class=\"w\"><footer><div>&copy; 2026 $BN</div><div><a href=\"/status\">Status</a> &middot; <a href=\"/terms\">Terms</a></div></footer></div>" ;;
    2)  # engineering notes / blog
      echo "<header><div class=\"w n\"><div class=\"b\">$BN<span>.</span></div>"
      echo '<nav><ul><li><a href="/archive">Archive</a></li><li><a href="/tags">Tags</a></li><li><a href="/about">About</a></li></ul></nav></div></header>'
      echo "<section class=\"h\"><div class=\"w\"><h1>$BT</h1>"
      echo '<p>Occasional write-ups about builds, failures and the things that only break in production.</p>'
      echo '<a class="btn" href="/archive">Browse the archive</a></div></section>'
      echo '<div class="w"><div class="g">'
      echo '<div class="c"><h3>Rewriting the scheduler</h3><p>Why we dropped the queue library and wrote 200 lines instead.</p></div>'
      echo '<div class="c"><h3>Notes on log retention</h3><p>Keeping 90 days without paying for 90 days.</p></div>'
      echo '<div class="c"><h3>A postmortem, honestly</h3><p>Four hours down, one missing index.</p></div>'
      echo '</div></div>'
      echo '<div class="st"><div class="w">'
      echo "<div class=\"s\"><b>$NPOST</b><span>Posts</span></div>"
      echo "<div class=\"s\"><b>$YEAR</b><span>First entry</span></div>"
      echo '<div class="s"><b>RSS</b><span>Always on</span></div>'
      echo '</div></div>'
      echo "<div class=\"w\"><footer><div>&copy; 2026 $BN</div><div><a href=\"/feed.xml\">RSS</a> &middot; <a href=\"/contact\">Contact</a></div></footer></div>" ;;
    *)  # documentation / handbook
      echo "<header><div class=\"w n\"><div class=\"b\">$BN<span>&middot;</span>docs</div>"
      echo '<nav><ul><li><a href="/guides">Guides</a></li><li><a href="/reference">Reference</a></li><li><a href="/faq">FAQ</a></li></ul></nav></div></header>'
      echo "<section class=\"h\"><div class=\"w\"><h1>$BT</h1>"
      echo '<p>Setup guides, reference material and the answers we got tired of repeating in chat.</p>'
      echo '<a class="btn" href="/guides/getting-started">Start here</a></div></section>'
      echo '<div class="w"><div class="g">'
      echo '<div class="c"><h3>Getting started</h3><p>Install, configure, run your first task in about ten minutes.</p></div>'
      echo '<div class="c"><h3>Configuration</h3><p>Every option, what it defaults to, and when you should not touch it.</p></div>'
      echo '<div class="c"><h3>Troubleshooting</h3><p>Common failures and how to read the logs when things go sideways.</p></div>'
      echo '</div></div>'
      echo '<div class="st"><div class="w">'
      echo "<div class=\"s\"><b>$NPOST+</b><span>Pages</span></div>"
      echo '<div class="s"><b>Weekly</b><span>Updated</span></div>'
      echo '<div class="s"><b>MIT</b><span>Licence</span></div>'
      echo '</div></div>'
      echo "<div class=\"w\"><footer><div>&copy; 2026 $BN</div><div><a href=\"/changelog\">Changelog</a> &middot; <a href=\"/contact\">Contact</a></div></footer></div>" ;;
  esac
  echo '</body></html>'
} > /var/www/html/index.html
grn "  static site: $BN (layout $LAYOUT)"

# ---------- 4. firewall ----------
if command -v ufw >/dev/null; then
  # An inactive ufw stores rules without enforcing any of them, and "no rule matches"
  # then reads as "port closed" when nothing is filtered at all. Enable it first so the
  # rest of this section means something. SSH is allowed before enabling, and ufw keeps
  # established connections, so the current session survives.
  if ! ufw status 2>/dev/null | grep -q "Status: active"; then
    ylw "  firewall: ufw was inactive - rules existed but nothing was enforced"
    ufw allow 22/tcp >/dev/null 2>&1 || true
    if ufw --force enable >/dev/null 2>&1; then
      grn "  firewall: enabled, SSH allowed first"
    else
      red "  firewall: could not enable ufw - every port stays reachable, fix by hand"
    fi
  fi

  # ufw allow only ever adds. Ports left over from an earlier layout stay open unless
  # their rules are deleted, so anything outside the intended set is dropped first.
  # Rules are matched by number and re-read every iteration, because deleting one
  # renumbers the rest. The counter is a guard against a rule that refuses to go away.
  drop_rules() {                       # drop_rules <extended-regex over the rule text>
    local re="$1" n guard=0
    while [ $guard -lt 40 ]; do
      n=$(ufw status numbered 2>/dev/null | grep -E "$re" | head -1 | sed -E 's/^\[[[:space:]]*([0-9]+)\].*/\1/' || true)
      [ -n "$n" ] || return 0
      ufw --force delete "$n" >/dev/null 2>&1 || return 0
      guard=$((guard + 1))
    done
  }

  # ports this layout does not use; also catches multiport rules like "443,2222/tcp"
  for p in 2053 8443; do
    drop_rules "^\[[ 0-9]+\].*(^|[^0-9])$p([^0-9]|\$)" && true
  done
  # any NODE_PORT rule that is not already limited to the panel
  drop_rules "^\[[ 0-9]+\].*2222.*(Anywhere|0\.0\.0\.0)"

  ufw allow 22/tcp  >/dev/null 2>&1 || true      # keep SSH reachable no matter what
  ufw allow 443/tcp >/dev/null
  ufw allow 443/udp >/dev/null
  ufw allow 80/tcp  >/dev/null
  ufw allow from "$PANEL_IP" to any port 2222 proto tcp >/dev/null
  ufw reload >/dev/null

  STILL=$(ufw status 2>/dev/null | grep -E '(^|[^0-9])(2053|8443)([^0-9]|$)' | head -3 || true)
  if ! ufw status 2>/dev/null | grep -q "Status: active"; then
    red "  firewall: ufw is still inactive - nothing below is enforced"
  elif [ -n "$STILL" ]; then
    ylw "  firewall: these rules survived, remove them by hand:"
    printf '%s\n' "$STILL" | sed 's/^/           /'
  else
    grn "  firewall: active; 22, 80, 443 tcp+udp; 2222 restricted to $PANEL_IP; 2053 and 8443 closed"
  fi
else
  ylw "  ufw not found - open the ports manually"
fi

# ---------- 4b. certificate ----------
# Runs after the firewall opened :80 and before nginx is (re)started, because
# certbot --standalone needs that port to itself.

cert_ok() {
  local d="$1" f="/etc/letsencrypt/live/$1/fullchain.pem"
  [ -f "$f" ] || return 1
  openssl x509 -in "$f" -noout -checkend 604800 >/dev/null 2>&1 || return 1   # >7 days left
  openssl x509 -in "$f" -noout -text 2>/dev/null | grep -q "DNS:$d" || return 1
}

# Certificates left over from a previous domain: this node serves exactly one.
if [ "${KEEP_CERTS:-0}" != "1" ]; then
  for c in $(certbot certificates 2>/dev/null | sed -n 's/^[[:space:]]*Certificate Name:[[:space:]]*//p'); do
    [ "$c" = "$DOMAIN" ] && continue
    ylw "  certificate: removing stale cert for $c"
    certbot delete --cert-name "$c" --non-interactive >/dev/null 2>&1 || true
  done
fi

if [ "${FORCE_CERT:-0}" = "1" ] && [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
  ylw "  certificate: --force-cert given, dropping the existing one"
  certbot delete --cert-name "$DOMAIN" --non-interactive >/dev/null 2>&1 || true
fi

if cert_ok "$DOMAIN"; then
  grn "  certificate: existing one is valid, reusing it"
else
  if [ -z "${EMAIL:-}" ] && can_ask; then
    ask "E-mail for expiry notices (optional, press Enter to skip)" EMAIL ".*" "-" || true
    [ "${EMAIL:-}" = "-" ] && EMAIL=""
  fi
  docker stop remnawave-nginx >/dev/null 2>&1 || true
  if [ -n "${EMAIL:-}" ]; then
    certbot certonly --standalone -d "$DOMAIN" --agree-tos --non-interactive \
            -m "$EMAIL" >/dev/null 2>&1 || true
  else
    certbot certonly --standalone -d "$DOMAIN" --agree-tos --non-interactive \
            --register-unsafely-without-email >/dev/null 2>&1 || true
  fi
  docker start remnawave-nginx >/dev/null 2>&1 || true
  cert_ok "$DOMAIN" || die "could not obtain a certificate for $DOMAIN.
  Check that the domain resolves to this host and that port 80 is reachable.
  Let's Encrypt allows 5 certificates per exact domain per week - if that limit
  was hit, the only option is to wait."
  grn "  certificate: issued for $DOMAIN"
fi

# ---------- 5. recreate containers and verify ----------
cd "$DIR"
docker compose pull >/dev/null 2>&1 || true
docker compose up -d --force-recreate >/dev/null
V=""
for _ in $(seq 1 15); do
  V=$(docker logs remnanode 2>&1 | grep -a -m1 "Xray version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  [ -n "$V" ] && break
  sleep 2
done
if [ "$V" = "$XRAY_EXPECT" ]; then
  grn "  core $V - matches the expected version"
else
  red "  Xray '${V:-unknown}', expected $XRAY_EXPECT - XHTTP+REALITY may not work"
fi
NGX_STATE=$(docker inspect -f '{{.State.Status}}' remnawave-nginx 2>/dev/null || echo missing)
if [ "$NGX_STATE" != "running" ]; then
  red "  nginx: container is '$NGX_STATE', not running"
  red "         last lines:"
  docker logs --tail 5 remnawave-nginx 2>&1 | sed 's/^/           /'
elif docker exec remnawave-nginx grep -q server_tokens /etc/nginx/conf.d/default.conf 2>/dev/null; then
  grn "  nginx: container is reading the new config"
else
  red "  nginx: container still sees the OLD config (inode-bound mount)"
fi

# ---------- 5b. certificate renewal: standalone -> webroot ----------
# nginx now holds :80, so certbot --standalone would fail on renewal.
# Switch to webroot and verify with a dry run; revert if it fails.
RCONF="/etc/letsencrypt/renewal/${DOMAIN}.conf"
if [ -f "$RCONF" ] && command -v certbot >/dev/null; then
  if grep -q '^authenticator[[:space:]]*=[[:space:]]*standalone' "$RCONF"; then
    cp "$RCONF" "${RCONF}.bak-$STAMP"
    sed -i -E 's|^authenticator[[:space:]]*=.*|authenticator = webroot|' "$RCONF"
    grep -q '^webroot_path' "$RCONF" && sed -i -E 's|^webroot_path[[:space:]]*=.*|webroot_path = /var/www/html,|' "$RCONF"                                      || sed -i -E '/^authenticator = webroot/a webroot_path = /var/www/html,' "$RCONF"
    if certbot renew --cert-name "$DOMAIN" --dry-run >/dev/null 2>&1; then
      grn "  certificate: renewal switched to webroot, dry run passed"
    else
      cp "${RCONF}.bak-$STAMP" "$RCONF"
      red "  certificate: webroot failed, reverted to standalone."
      red "              Renewal now conflicts with nginx on :80 - fix this manually!"
    fi
  else
    if certbot renew --cert-name "$DOMAIN" --dry-run >/dev/null 2>&1; then
      grn "  certificate: renewal works"
    else
      ylw "  certificate: renewal dry run failed - check 'certbot renew --dry-run'"
    fi
  fi
else
  ylw "  certificate: renewal config or certbot not found, renewal not verified"
fi

# ---------- 6. keys and panel values ----------
KEYS=$(docker exec remnanode xray x25519 2>/dev/null || true)
PRIV=$(printf '%s' "$KEYS" | grep -i 'private' | awk '{print $NF}' || true)
PUB=$(printf '%s' "$KEYS" | grep -i 'public' | awk '{print $NF}' || true)
SID=$(openssl rand -hex 8)
SALT=$(openssl rand -hex 32)
SUF=$(printf '%s' "$DOMAIN" | md5sum | cut -c1-4 | tr 'a-z' 'A-Z')
PATHS=("/api/collect/" "/assets/live/" "/media/segments/" "/v1/events/" "/static/chunks/" "/api/feed/" "/data/sync/" "/pub/updates/")
XPATH="${PATHS[$(( 10#$H % ${#PATHS[@]} ))]}"
SEQ=$(tr -dc 'a-z' </dev/urandom | head -c1 || true)
SES=$(tr -dc 'a-z' </dev/urandom | head -c1 || true)
FF=$(( 140 + 10#$H % 15 ))
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:${FF}.0) Gecko/20100101 Firefox/${FF}.0"
SESSTAB="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
CERTF="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEYF="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
OUT="/root/${DOMAIN}-panel.txt"

{
  echo "================ $DOMAIN - panel values ================"
  echo
  echo "--- config profile: paste as a whole ---"
  echo '{'
  echo '  "log": { "loglevel": "warning" },'
  echo '  "dns": { "servers": [{ "address": "https://1.1.1.1/dns-query", "skipFallback": false }, "1.1.1.1"],'
  echo '           "queryStrategy": "UseIPv4", "disableCache": false, "disableFallback": false },'
  echo '  "inbounds": ['
  echo '    {'
  echo "      \"tag\": \"XHTTP-REALITY-$SUF\", \"port\": 443, \"protocol\": \"vless\","
  echo '      "settings": { "clients": [], "decryption": "none" },'
  echo '      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "routeOnly": true },'
  echo '      "streamSettings": {'
  echo '        "network": "xhttp", "security": "reality",'
  echo '        "xhttpSettings": {'
  echo "          \"host\": \"$DOMAIN\", \"path\": \"$XPATH\", \"mode\": \"stream-one\","
  echo '          "xmux": { "maxConnections": "2", "cMaxReuseTimes": "128-256", "hKeepAlivePeriod": 45,'
  echo '                    "hMaxRequestTimes": "600-900", "hMaxReusableSecs": "1800-3600" },'
  echo "          \"extra\": { \"noGRPCHeader\": true, \"seqKey\": \"$SEQ\", \"seqPlacement\": \"path\","
  echo "                     \"sessionKey\": \"$SES\", \"sessionPlacement\": \"path\","
  echo "                     \"sessionTable\": \"$SESSTAB\","
  echo "                     \"sessionLength\": \"16-32\", \"headers\": { \"User-Agent\": \"$UA\" } },"
  echo '          "xPaddingBytes": "100-1000"'
  echo '        },'
  echo '        "realitySettings": { "show": false, "dest": "/dev/shm/nginx.sock", "xver": 1,'
  echo "          \"serverNames\": [\"$DOMAIN\"], \"privateKey\": \"$PRIV\", \"shortIds\": [\"$SID\"],"
  echo '          "fingerprint": "firefox", "spiderX": "/" }'
  echo '      }'
  echo '    },'
  echo '    {'
  echo "      \"tag\": \"HYSTERIA-$SUF\", \"port\": 443, \"listen\": \"0.0.0.0\", \"protocol\": \"hysteria\","
  echo '      "settings": { "clients": [], "version": 2 },'
  echo '      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "routeOnly": true },'
  echo '      "streamSettings": { "network": "hysteria", "security": "tls",'
  echo "        \"finalmask\": { \"obfs\": { \"type\": \"salamander\", \"password\": \"$SALT\", \"packetSize\": \"512-1200\" },"
  echo '                       "quicParams": { "debug": false, "congestion": "bbr" } },'
  echo '        "tlsSettings": { "alpn": ["h3"],'
  echo "          \"certificates\": [{ \"certificateFile\": \"$CERTF\", \"keyFile\": \"$KEYF\" }] },"
  echo '        "hysteriaSettings": { "version": 2 } }'
  echo '    }'
  echo '  ],'
  echo '  "outbounds": ['
  echo '    { "tag": "DIRECT", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },'
  echo '    { "tag": "BLOCK", "protocol": "blackhole" }'
  echo '  ],'
  echo '  "routing": { "domainStrategy": "IPIfNonMatch", "rules": ['
  echo '    { "type": "field", "ip": ["geoip:private"], "outboundTag": "BLOCK" },'
  echo '    { "type": "field", "protocol": ["bittorrent"], "outboundTag": "BLOCK" }'
  echo '  ]}'
  echo '}'
  echo
  echo "--- Host: $DOMAIN [xhttp] ---"
  echo "Inbound    : XHTTP-REALITY-$SUF"
  echo "Address    : $DOMAIN / 443"
  echo "SNI        : $DOMAIN"
  echo "Fingerprint: firefox"
  echo "Path/ALPN  : leave empty (taken from the inbound)"
  echo "xHTTP button:"
  echo "{ \"xmux\": { \"maxConnections\": \"2\", \"cMaxReuseTimes\": \"128-256\", \"hKeepAlivePeriod\": 45,"
  echo "            \"hMaxRequestTimes\": \"600-900\", \"hMaxReusableSecs\": \"1800-3600\" },"
  echo "  \"seqKey\": \"$SEQ\", \"seqPlacement\": \"path\", \"sessionKey\": \"$SES\", \"sessionPlacement\": \"path\","
  echo "  \"sessionTable\": \"$SESSTAB\","
  echo "  \"sessionLength\": \"16-32\", \"noGRPCHeader\": true,"
  echo "  \"headers\": { \"User-Agent\": \"$UA\" }, \"xPaddingBytes\": \"100-1000\" }"
  echo
  echo "--- Host: $DOMAIN [hy2] ---"
  echo "Inbound    : HYSTERIA-$SUF"
  echo "Address    : $DOMAIN / 443     ALPN: h3"
  echo "Final Mask button:"
  echo "{ \"obfs\": { \"type\": \"salamander\", \"password\": \"$SALT\" } }"
  echo
  echo "--- node keys ---"
  echo "REALITY privateKey : $PRIV"
  echo "REALITY publicKey  : $PUB"
  echo "shortId            : $SID"
  echo "Salamander         : $SALT"
} > "$OUT"
chmod 600 "$OUT"

# ---------- 7. install as `rr` for quick re-runs ----------
# Fetched fresh rather than copied from $0: under bash <(curl ...) the script
# arrives on a pipe that has already been consumed and cannot be read again.
# Syntax-checked before it replaces anything, so a truncated download cannot
# leave a broken command behind.
RAW_URL="https://raw.githubusercontent.com/pret3nder/edge-bootstrap/master/node-setup.sh"
if command -v curl >/dev/null; then
  if curl -fsSL --max-time 20 "$RAW_URL" -o /usr/local/bin/.rr.tmp 2>/dev/null \
     && bash -n /usr/local/bin/.rr.tmp 2>/dev/null; then
    mv /usr/local/bin/.rr.tmp /usr/local/bin/rr
    chmod +x /usr/local/bin/rr
    RR_READY=1
  else
    rm -f /usr/local/bin/.rr.tmp
    RR_READY=0
  fi
else
  RR_READY=0
fi

echo
grn "=== done ==="
echo "Panel values: $OUT"
echo
ylw "Verify from outside:"
echo "  curl -sI https://$DOMAIN/ | head -2"
echo "  curl -so /dev/null -w '%{http_code}\\n' https://$DOMAIN/wp-admin"
echo
ylw "Next: paste the config profile from that file into the panel, then add the hosts."
if [ "${RR_READY:-0}" = "1" ]; then
  echo
  grn "Installed as 'rr' - re-run on this host with:  rr $DOMAIN"
fi
