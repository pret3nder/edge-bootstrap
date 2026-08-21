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

RE_DOMAIN='^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$'
RE_IP='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

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
    }')
  [ -n "$PANEL_IP" ]
}

[ "$(id -u)" = "0" ] || die "must run as root"
if [ -z "$DOMAIN" ]; then
  ask "Node domain (selfsteal domain used during installation)" DOMAIN "$RE_DOMAIN"     || die "domain required: bash node-setup.sh node.example.com"
fi
printf "%s" "$DOMAIN" | grep -qE "$RE_DOMAIN" || die "not a valid domain: $DOMAIN"
[ -d "$DIR" ] || die "$DIR not found - run the stock installer first"
[ -f "$DIR/docker-compose.yml" ] || die "missing $DIR/docker-compose.yml"
command -v docker >/dev/null || die "docker is not installed"
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
mkdir -p /var/www/html
H=$(printf '%s' "$DOMAIN" | md5sum | tr -dc '0-9' | cut -c1-6)
[ -z "$H" ] && H=1
BRANDS=("Northwind|Infrastructure notes and tooling|#3b6ea5"
        "Kestrel|Small tools, done properly|#2f7a5b"
        "Basalt|Systems engineering studio|#8a4b2a"
        "Vellum|Documentation and handbooks|#5a4b8a"
        "Tessera|Data plumbing for small teams|#2b6b7a"
        "Halcyon|Software, unhurried|#2b5a7a"
        "Ridgeway|Practical automation|#7a5a2b"
        "Lumen|Interfaces and prototypes|#7a3f5a")
IDX=$(( 10#$H % ${#BRANDS[@]} ))
BN="${BRANDS[$IDX]%%|*}"
REST="${BRANDS[$IDX]#*|}"
BT="${REST%%|*}"
BC="${REST#*|}"
YEAR=$(( 2016 + 10#$H % 8 ))
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
  echo '<div class="s"><b>40+</b><span>Projects shipped</span></div>'
  echo '<div class="s"><b>6</b><span>People</span></div>'
  echo '</div></div>'
  echo "<div class=\"w\"><footer><div>&copy; 2026 $BN</div><div><a href=\"/privacy\">Privacy</a> &middot; <a href=\"/contact\">Contact</a></div></footer></div>"
  echo '</body></html>'
} > /var/www/html/index.html
grn "  static site: $BN"

# ---------- 4. firewall ----------
if command -v ufw >/dev/null; then
  while ufw status numbered 2>/dev/null | grep -qE '^\[[ 0-9]+\].*2222.*Anywhere'; do
    N=$(ufw status numbered | grep -E '^\[[ 0-9]+\].*2222.*Anywhere' | head -1 | sed -E 's/^\[[[:space:]]*([0-9]+)\].*/\1/')
    ufw --force delete "$N" >/dev/null
  done
  ufw allow 443/tcp >/dev/null
  ufw allow 443/udp >/dev/null
  ufw allow 80/tcp  >/dev/null
  ufw allow from "$PANEL_IP" to any port 2222 proto tcp >/dev/null
  ufw reload >/dev/null
  grn "  firewall: 80, 443 tcp+udp; 2222 restricted to $PANEL_IP"
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
if docker exec remnawave-nginx grep -qc server_tokens /etc/nginx/conf.d/default.conf 2>/dev/null; then
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
PRIV=$(printf '%s' "$KEYS" | grep -i 'private' | awk '{print $NF}')
PUB=$(printf '%s' "$KEYS" | grep -i 'public' | awk '{print $NF}')
SID=$(openssl rand -hex 8)
SALT=$(openssl rand -hex 32)
SUF=$(printf '%s' "$DOMAIN" | md5sum | cut -c1-4 | tr 'a-z' 'A-Z')
PATHS=("/api/collect/" "/assets/live/" "/media/segments/" "/v1/events/" "/static/chunks/" "/api/feed/" "/data/sync/" "/pub/updates/")
XPATH="${PATHS[$(( 10#$H % ${#PATHS[@]} ))]}"
SEQ=$(tr -dc 'a-z' </dev/urandom | head -c1)
SES=$(tr -dc 'a-z' </dev/urandom | head -c1)
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

echo
grn "=== done ==="
echo "Panel values: $OUT"
echo
ylw "Verify from outside:"
echo "  curl -sI https://$DOMAIN/ | head -2"
echo "  curl -so /dev/null -w '%{http_code}\\n' https://$DOMAIN/wp-admin"
echo
ylw "Next: paste the config profile from that file into the panel, then add the hosts."
