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
  out=$(grep -oE '/etc/letsencrypt/live/[^/]+/fullchain\.pem' "$DIR/docker-compose.yml" 2>/dev/null | head -1 | sed -E 's|.*/live/([^/]+)/.*|\1|' || true)
  # A wildcard is stored under the apex, so a mount naming the parent of the
  # served domain is correct and must not be reported as a mismatch.
  if [ -n "$out" ] && [ -n "$d" ] && [ "$out" != "$d" ] && [ "${d%".$out"}" = "$d" ]; then
    red "  compose: certificate mount points at $out, node serves $d"
    fails=$((fails + 1))
  elif [ -n "$out" ] && [ "$out" != "$d" ]; then
    grn "  compose: certificate mount uses the wildcard for $out"
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
    # The stock installer leaves a Vite shell titled Page_<8 hex>, with a
    # config-id meta and a hex HTML comment. Only those hex tokens vary, so
    # every node running it serves the same structure - and it ships with a
    # public installer, which makes it a signature anyone can grep the internet
    # for. Present here means this node was never re-done with this script.
    if grep -qE '<title>Page_[0-9a-f]{8}</title>' /var/www/html/index.html 2>/dev/null; then
      red "  static site: still the stock installer's placeholder (title Page_xxxxxxxx)"
      red "              Same structure on every node that has it, from a public template."
      red "              Re-run setup on this node to replace it."
      fails=$((fails + 1))
    else
      grn "  static site: present ($(grep -m1 -oE '<title>[^<]*' /var/www/html/index.html 2>/dev/null | sed 's/<title>//' || echo untitled))"
    fi
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
    printf '    4) export certificate bundle for other nodes\n' >/dev/tty
    printf '    0) exit\n' >/dev/tty
    printf '  choice: ' >/dev/tty
    read -r choice </dev/tty || return 1
    case "$choice" in
      1) ACTION=setup; return 0 ;;
      2) ACTION=check; return 0 ;;
      3) ACTION=panel; return 0 ;;
      4) ACTION=cert-export; return 0 ;;
      0) exit 0 ;;
      *) red "  pick 0-4" >/dev/tty ;;
    esac
  done
}

RE_DOMAIN='^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$'
RE_IP='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
# These go to grep -E. BRE interval syntax (\{8,\}) reads as a literal brace
# there and matches nothing, which rejects every value the user types.
RE_TOKEN='^[^[:space:]]{16,}$'

# ---------------------------------------------------------------------------
# Bare-metal install. Everything the node needs, so a fresh server goes from
# nothing to a configured node in one run.
# ---------------------------------------------------------------------------
install_prereqs() {
  local want="" c
  for c in curl certbot ufw openssl; do
    command -v "$c" >/dev/null 2>&1 || want="$want $c"
  done
  command -v docker >/dev/null 2>&1 || want="$want docker.io"

  if [ -n "$want" ]; then
    ylw "  installing:$want"
    apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $want >/dev/null 2>&1 || true
  fi

  # compose v2 ships as its own package on Ubuntu; without it "docker compose"
  # is not a command and every later step fails in a confusing way.
  if ! docker compose version >/dev/null 2>&1; then
    ylw "  installing: docker-compose-v2"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-v2 >/dev/null 2>&1 \
      || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 \
      || true
  fi

  systemctl enable --now docker >/dev/null 2>&1 || true
}

install_node() {
  ylw "  no node in $DIR - installing one"
  install_prereqs
  command -v docker >/dev/null 2>&1 || die "docker could not be installed"
  docker compose version >/dev/null 2>&1 || die "docker compose v2 could not be installed"

  # The key identifies this node to the panel. It is created when the node is
  # added there and is copied from its card; nothing generates it locally.
  if [ -z "${SECRET_KEY:-}" ]; then
    echo >/dev/tty
    ylw "  Open the node in the panel and copy its SECRET_KEY." >/dev/tty
    ask "SECRET_KEY" SECRET_KEY '^[A-Za-z0-9+/=_-]{80,}$' \
      || die "SECRET_KEY is required - pass it with --secret-key <value>"
  fi

  mkdir -p "$DIR" /var/www/html
  cat > "$DIR/docker-compose.yml" <<COMPOSE
x-common: &common
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  restart: always

x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 10m
      max-file: "3"

services:
  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    <<: [*common, *logging]
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /etc/letsencrypt/live/$CERTNAME/fullchain.pem:/etc/nginx/ssl/$CERTNAME/fullchain.pem:ro
      - /etc/letsencrypt/live/$CERTNAME/privkey.pem:/etc/nginx/ssl/$CERTNAME/privkey.pem:ro
      - /dev/shm:/dev/shm:rw
      - /var/www/html:/var/www/html:ro
    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'

  remnanode:
    image: $NODE_IMAGE
    container_name: remnanode
    hostname: remnanode
    <<: [*common, *logging]
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=$SECRET_KEY
    volumes:
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - /dev/shm:/dev/shm:rw
COMPOSE
  chmod 600 "$DIR/docker-compose.yml"
  grn "  node installed in $DIR"

}

# Pack this node's certificate for the rest of the fleet. Let's Encrypt caps
# identical certificates at five a week, so one host issues the wildcard and
# every other node imports the result rather than asking for its own.
cmd_cert_export() {
  local out="${1:-}" name
  name=$(grep -m1 -oE '/etc/letsencrypt/live/[^/]+/fullchain\.pem' "$DIR/docker-compose.yml" 2>/dev/null | sed -E 's|.*/live/([^/]+)/.*|\1|' || true)
  [ -n "$name" ] || die "cannot tell which certificate this node uses - no $DIR/docker-compose.yml?"
  [ -f "/etc/letsencrypt/live/$name/fullchain.pem" ] || die "no certificate at /etc/letsencrypt/live/$name"
  [ -n "$out" ] || out="/root/$name-cert.tgz"
  # -h dereferences: live/ holds symlinks into archive/, and the targets have to travel.
  tar -czhf "$out" -C /etc/letsencrypt/live "$name" 2>/dev/null || die "could not write $out"
  chmod 600 "$out"
  grn "certificate bundle written: $out"
  openssl x509 -in "/etc/letsencrypt/live/$name/fullchain.pem" -noout -subject -enddate 2>/dev/null | sed 's/^/  /'
  echo
  echo "  Copy it to another node, then there:"
  echo "    rr <node-domain> --cert-mode dns --cert-bundle /root/$(basename "$out")"
  echo
  echo "  Renewal stays on this host. Re-export and re-import before expiry."
}
# First positional argument is either a sub-command or the domain.
ACTION=setup
case "${1:-}" in
  check|panel|setup) ACTION="$1"; shift ;;
  cert-export)       ACTION=cert-export; shift ;;
  menu)              ACTION=menu; shift ;;
esac

CERT_MODE=http
CERT_MODE_SET=0
GCORE_TOKEN="${GCORE_API_TOKEN:-}"

DOMAIN="${1:-}"
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    --panel-ip)    shift; PANEL_IP="${1:-}" ;;
    --email)       shift; EMAIL="${1:-}" ;;
    --force-cert)  FORCE_CERT=1 ;;
    --keep-certs)  KEEP_CERTS=1 ;;
    --new-site)    NEW_SITE=1 ;;
    --brand)       shift; BRAND="${1:-}" ;;
    --secret-key)  shift; SECRET_KEY="${1:-}" ;;
    --cert-mode)   shift; CERT_MODE="${1:-}"; CERT_MODE_SET=1 ;;
    --gcore-token) shift; GCORE_TOKEN="${1:-}" ;;
    --cert-bundle) shift; CERT_BUNDLE="${1:-}" ;;
    --apex)        shift; APEX_OVERRIDE="${1:-}" ;;
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
NEED_INSTALL=0
if [ ! -f "$DIR/docker-compose.yml" ]; then
  [ "$ACTION" = "setup" ] || die "no node in $DIR - run a setup pass first"
  NEED_INSTALL=1
fi

# With no arguments at all and a terminal available, offer the menu.
if [ "$ACTION" = "setup" ] && [ -z "$DOMAIN" ] && can_ask && [ -f "$DIR/nginx.conf" ]; then
  ACTION=menu
fi
[ "$ACTION" = "menu" ] && { menu || die "no terminal for the menu"; }

# A copy that lost its tail still parses, and only fails later when the dispatch
# reaches for a function that is not there - which reads as
# "line 424: cmd_cert_export: command not found" and blames the wrong thing.
# Seen in the field. Check up front and say what is actually wrong.
for _f in cmd_check cmd_panel cmd_cert_export menu install_node; do
  declare -F "$_f" >/dev/null 2>&1 || die "this copy of the script is incomplete: $_f is missing.
  It parsed, so the download was cut at a point that happens to be valid syntax.
  Replace it:
    curl -Ls 'https://raw.githubusercontent.com/pret3nder/edge-bootstrap/master/node-setup.sh?'\$(date +%s) -o /usr/local/bin/rr && chmod +x /usr/local/bin/rr"
done

case "$ACTION" in
  check) cmd_check "$DOMAIN"; exit 0 ;;
  panel) cmd_panel "$DOMAIN"; exit $? ;;
  cert-export) cmd_cert_export "$DOMAIN"; exit 0 ;;
esac

# ---- from here on: setup ----
if [ -z "$DOMAIN" ]; then
  ask "Node domain (selfsteal domain used during installation)" DOMAIN "$RE_DOMAIN"     || die "domain required: bash node-setup.sh node.example.com"
fi
printf "%s" "$DOMAIN" | grep -qE "$RE_DOMAIN" || die "not a valid domain: $DOMAIN"


# Certificate mode. This is the one choice whose consequence is invisible
# afterwards - the node looks identical either way - so it is asked rather than
# defaulted quietly. A bundle only makes sense for the wildcard, so it decides
# on its own.
if [ -n "${CERT_BUNDLE:-}" ] && [ "$CERT_MODE_SET" = "0" ]; then
  CERT_MODE=dns; CERT_MODE_SET=1
fi
if [ "$CERT_MODE_SET" = "0" ] && can_ask; then
  printf '\n\033[33m  Certificate for %s\033[0m\n' "$DOMAIN" >/dev/tty
  printf "    1) per-node, Let's Encrypt over HTTP-01   (as before, nothing to set up)\n" >/dev/tty
  printf '       Publishes %s to the public Certificate Transparency logs,\n' "$DOMAIN" >/dev/tty
  printf '       where anyone can list every node under the same apex.\n' >/dev/tty
  printf '    2) one wildcard for the apex over DNS-01 via Gcore\n' >/dev/tty
  printf '       CT shows *.<apex> and nothing else, so node names stay unlisted.\n' >/dev/tty
  printf '       Needs a Gcore API token and the apex zone hosted at Gcore.\n' >/dev/tty
  CERT_CHOICE=1
  ask "  choice" CERT_CHOICE '^[12]$' 1 || CERT_CHOICE=1
  [ "$CERT_CHOICE" = "2" ] && CERT_MODE=dns
fi
# Which certificate this node runs on, and which name it has to contain.
# http: one per node, named after the node. dns: one wildcard for the apex,
# shared by the fleet. Everything downstream - the compose mounts, the nginx
# paths, the renewal config, the Hysteria2 certificate - keys off CERTNAME.
case "$CERT_MODE" in
  http)
    CERTNAME="$DOMAIN"; CERTWANT="$DOMAIN"; APEX="$DOMAIN" ;;
  dns)
    APEX="${APEX_OVERRIDE:-${DOMAIN#*.}}"
    # Stripping one label is right for node.example.com and wrong for anything
    # under a multi-part suffix, so the guess is checked and can be overridden.
    [ "$APEX" != "$DOMAIN" ] || die "--cert-mode dns needs a node under an apex, got $DOMAIN.
  Name the zone explicitly if the guess cannot work: --apex example.com"
    printf '%s' "$APEX" | grep -qE '^[a-z0-9-]+\.[a-z]{2,}$' \
      || ylw "  certificate: apex guessed as $APEX - pass --apex if that is wrong"
    CERTNAME="$APEX"; CERTWANT="*.$APEX" ;;
  *)
    die "unknown --cert-mode: $CERT_MODE (expected http or dns)" ;;
esac

# Issue or import. One wildcard serves the whole fleet, and Let's Encrypt allows
# five identical certificates per week, so a node that issues its own instead of
# importing burns a slot the fleet cannot spare. Nothing here can see the other
# nodes, so the choice is put to the operator rather than guessed - and the
# import is what the default lands on.
if [ "$CERT_MODE" = "dns" ] && [ -z "${CERT_BUNDLE:-}" ] \
   && [ ! -f "/etc/letsencrypt/live/$CERTNAME/fullchain.pem" ] && can_ask; then
  printf '\n\033[33m  Wildcard for *.%s\033[0m\n' "$APEX" >/dev/tty
  printf '    This node has no certificate yet. Two ways to get one:\n' >/dev/tty
  printf '    1) import the bundle another node already issued   (recommended)\n' >/dev/tty
  printf '       Make it there with:  rr cert-export\n' >/dev/tty
  printf '    2) issue a new wildcard from Let%s Encrypt now\n' "'s" >/dev/tty
  printf '       Costs one of five per week for the whole fleet, shared by every node.\n' >/dev/tty
  printf '       Correct for the first node, and wasteful for the rest.\n' >/dev/tty
  CERT_SRC=1
  ask "  choice" CERT_SRC '^[12]$' 1 || CERT_SRC=1
  if [ "$CERT_SRC" = "1" ]; then
    # The bundle usually is not here yet at this point, and a prompt that only
    # accepts an absolute path is a dead end when the answer is "I have not made
    # it". "-" backs out to issuing rather than forcing a Ctrl+C and a re-run.
    printf '    Not made yet? Run  rr cert-export  on a node that has the wildcard and\n' >/dev/tty
    printf '    copy the file over. Enter - to issue a new one instead.\n' >/dev/tty
    ask "  path to the bundle (or -)" CERT_BUNDLE '^(/.+|-)$' || CERT_BUNDLE="-"
    if [ "$CERT_BUNDLE" = "-" ]; then
      CERT_BUNDLE=""
      ylw "  certificate: issuing a new wildcard - one of five per week for the fleet"
    elif [ ! -f "$CERT_BUNDLE" ]; then
      die "no such file: $CERT_BUNDLE
  Run 'rr cert-export' on the node that already holds the wildcard, copy the
  file here, then re-run with --cert-bundle <path>."
    fi
  fi
fi

# Re-runs should not need the token pasted again.
if [ "$CERT_MODE" = "dns" ] && [ -z "${GCORE_TOKEN:-}" ] && [ -z "${CERT_BUNDLE:-}" ] && [ -s "$DIR/.gcore-token" ]; then
  GCORE_TOKEN=$(cat "$DIR/.gcore-token")
  grn "  certificate: reusing the Gcore token already stored on this host"
fi
# Asked here rather than at issuing time: by then compose, nginx and the site
# have been rewritten, and stopping to prompt in the middle of that is worse
# than failing before anything was touched.
if [ "$CERT_MODE" = "dns" ] && [ -z "${GCORE_TOKEN:-}" ] && [ -z "${CERT_BUNDLE:-}" ] && can_ask; then
  ask "  Gcore API token" GCORE_TOKEN "$RE_TOKEN" || true
fi

# Domain is known now, so the compose file can name the right certificate paths.
[ "$NEED_INSTALL" = "1" ] && install_node
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
# The file holds SECRET_KEY, and awk-into-temp-then-mv resets the mode to 0644.
chmod 600 "$DIR/docker-compose.yml" 2>/dev/null || true
if grep -q '/etc/letsencrypt:/etc/letsencrypt' "$DIR/docker-compose.yml"; then
  grn "  compose: image pinned, certificate mount present"
else
  ylw "  compose: could not add the /etc/letsencrypt mount - check manually"
fi

# nginx mounts the certificate by explicit path, so repointing the node at another
# domain means rewriting those two lines. Left alone, nginx keeps loading a path that
# no longer exists, docker helpfully creates a directory there, and the container
# ends up in a restart loop.
OLDCERT=$(grep -oE '/etc/letsencrypt/live/[^/]+/fullchain\.pem' "$DIR/docker-compose.yml" | head -1 | sed -E 's|.*/live/([^/]+)/.*|\1|' || true)
if [ -n "$OLDCERT" ] && [ "$OLDCERT" != "$CERTNAME" ]; then
  sed -i -E "s|/etc/letsencrypt/live/[^/]+/(fullchain\|privkey)\.pem:/etc/nginx/ssl/[^/]+/(fullchain\|privkey)\.pem|/etc/letsencrypt/live/$CERTNAME/\1.pem:/etc/nginx/ssl/$CERTNAME/\2.pem|g" \
      "$DIR/docker-compose.yml"
  grn "  compose: certificate mounts repointed $OLDCERT -> $CERTNAME"
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
  echo "    ssl_certificate         \"/etc/nginx/ssl/$CERTNAME/fullchain.pem\";"
  echo "    ssl_certificate_key     \"/etc/nginx/ssl/$CERTNAME/privkey.pem\";"
  echo "    ssl_trusted_certificate \"/etc/nginx/ssl/$CERTNAME/fullchain.pem\";"
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
# Two nodes serving pages that differ only in wording still share a stylesheet,
# and a matching stylesheet is the easier thing to correlate on. So the page is
# generated rather than filled in: class names, palette, type, spacing, section
# counts and the copy all come from one per-node seed.
#
# The seed is random and stored in $DIR/.site-seed. Deriving it from the domain
# — which is what this did first — caps the whole fleet at the size of the word
# lists, so nodes start repeating each other as the fleet grows. A stored random
# seed keeps re-runs reproducible (same node rebuilds the same site) while the
# space stays far larger than any fleet. --new-site rerolls it, --brand overrides
# the name outright when a specific one is wanted.
mkdir -p /var/www/html
SEEDF="$DIR/.site-seed"
if [ "${NEW_SITE:-0}" = "1" ] || [ ! -s "$SEEDF" ]; then
  # Whatever produces it, the seed is checked before it is kept: an openssl that
  # exits 0 and prints something other than hex would otherwise be trusted.
  SEED=""
  if command -v openssl >/dev/null 2>&1; then
    SEED=$(openssl rand -hex 64 2>/dev/null | tr -dc 'a-f0-9' || true)
  fi
  if [ "${#SEED}" -lt 128 ]; then
    SEED=$(head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' || true)
  fi
  [ "${#SEED}" -ge 128 ] || die "cannot generate a site seed: no working openssl and /dev/urandom unreadable"
  printf '%s\n' "$SEED" > "$SEEDF"
  chmod 600 "$SEEDF" 2>/dev/null || true
fi
HX=$(tr -dc 'a-f0-9' < "$SEEDF")
[ "${#HX}" -ge 128 ] || die "site seed is short or unreadable: $SEEDF (delete it and re-run)"
hb() { printf '%d' "0x${HX:$(( $1 * 2 )):2}"; }   # byte N of the seed, 0-255

# HSL -> hex in integer arithmetic. The accent comes out of a colour space
# rather than a list of sixteen, and saturation and lightness stay in a narrow
# band so the result is a plausible brand colour and not a random RGB triple.
hsl_hex() {
  local h=$1 s=$2 l=$3 a c hp d x m r g b
  a=$(( l * 2 - 100 )); if [ "$a" -lt 0 ]; then a=$(( 0 - a )); fi
  c=$(( (100 - a) * s / 100 ))
  hp=$(( h * 100 / 60 ))
  d=$(( hp % 200 - 100 )); if [ "$d" -lt 0 ]; then d=$(( 0 - d )); fi
  x=$(( c * (100 - d) / 100 ))
  m=$(( l - c / 2 ))
  case $(( h / 60 )) in
    0) r=$c; g=$x; b=0  ;;
    1) r=$x; g=$c; b=0  ;;
    2) r=0;  g=$c; b=$x ;;
    3) r=0;  g=$x; b=$c ;;
    4) r=$x; g=0;  b=$c ;;
    *) r=$c; g=0;  b=$x ;;
  esac
  printf '#%02x%02x%02x' $(( (r + m) * 255 / 100 )) $(( (g + m) * 255 / 100 )) $(( (b + m) * 255 / 100 ))
}

PRE=(Ash Bram Cald Dun Ever Fen Gart Hark Ives Kel Lyn Mor Oak Pell Rown Stan
     Thorn Vane Wend Yar Alder Bick Cran Dray Elms Far Glen Hol Kirk Lang Nor Sel
     Ald Barr Colt Dane Esk Fal Grim Haw Ing Lark Mel Ness Orm Quill Redd Sax)
SFX=(gate mere ridge dale field crest brook stone wick ford mont holt
     bury cliff marsh haven hurst port side well worth combe glen moor
     bank cote leigh shaw thwaite vale wold reach)
CORP=(Labs Works Studio Group Systems Digital Collective Partners
      Industries Consulting Technologies Associates)
TAGS=("Infrastructure notes and tooling" "Small tools, done properly"
      "Systems engineering studio" "Documentation and handbooks"
      "Data plumbing for small teams" "Software, unhurried"
      "Practical automation" "Interfaces and prototypes"
      "Scheduling for background work" "Field notes on small systems"
      "Backend consulting" "Build and release tooling"
      "Monitoring without the noise" "Data pipelines, plainly"
      "Status pages and alerting" "Storage and archival")
FONTS=('-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif'
       '"Inter","Helvetica Neue",Helvetica,Arial,sans-serif'
       'Georgia,"Times New Roman",Times,serif'
       'system-ui,"Segoe UI",Roboto,"Noto Sans",sans-serif'
       '"Segoe UI",Tahoma,Geneva,Verdana,sans-serif'
       'ui-sans-serif,system-ui,-apple-system,"Helvetica Neue",sans-serif'
       '"Charter","Iowan Old Style",Georgia,serif'
       'Verdana,Geneva,"DejaVu Sans",sans-serif')
# Class names are drawn from one pool without replacement, so the markup does
# not fall into a handful of recognisable sets.
CPOOL=(wrap container shell page frame layout holder canvas inner bound
       nav topbar bar navrow menu headnav crossbar
       brand logo mark title sig ident
       hero lead intro masthead banner opener
       grid cols items list tiles deck cluster
       card panel box tile unit cell block
       strip band ribbon rail belt
       stat figure metric number datum counter)

POOL=("${CPOOL[@]}")
PICK=()
for i in 0 1 2 3 4 5 6 7 8 9; do
  n=${#POOL[@]}
  idx=$(( $(hb $(( 24 + i ))) % n ))
  PICK+=("${POOL[$idx]}")
  POOL=( "${POOL[@]:0:$idx}" "${POOL[@]:$(( idx + 1 ))}" )
done
W=${PICK[0]}; NAVC=${PICK[1]}; BR=${PICK[2]}; HERO=${PICK[3]}; GR=${PICK[4]}
CD=${PICK[5]}; SP=${PICK[6]}; ST=${PICK[7]}; BTN=${PICK[8]}; FT=${PICK[9]}

LAYOUT=$(( $(hb 5) % 4 ))
FSTACK="${FONTS[$(( $(hb 6) % 8 ))]}"
case $(( $(hb 7) % 4 )) in 0) R=0px ;; 1) R=3px ;; 2) R=6px ;; *) R=10px ;; esac
MAXW=$(( 840 + $(hb 8) % 9 * 30 ))
BASE=$(( 15 + $(hb 9) % 3 ))
H1=$(( 30 + $(hb 10) % 15 ))
PADY=$(( 48 + $(hb 11) % 40 ))
YEAR=$(( 2011 + $(hb 12) % 14 ))
N1=$(( 18 + $(hb 13) % 90 ))
N2=$(( 3 + $(hb 14) % 40 ))
BC=$(hsl_hex $(( $(hb 15) * 360 / 256 )) $(( 26 + $(hb 16) % 34 )) $(( 27 + $(hb 17) % 17 )))
NCARD=$(( 3 + $(hb 18) % 4 ))
NSTAT=$(( 2 + $(hb 19) % 3 ))
NNAV=$(( 3 + $(hb 20) % 2 ))

if [ -n "${BRAND:-}" ]; then
  BN="$BRAND"
else
  BN="${PRE[$(( $(hb 1) % 48 ))]}${SFX[$(( $(hb 2) % 32 ))]}"
  [ $(( $(hb 0) % 3 )) = 0 ] || BN="$BN ${CORP[$(( $(hb 3) % 12 ))]}"
fi
BT="${TAGS[$(( $(hb 4) % 16 ))]}"

case "$LAYOUT" in
  0) NAVW=(Work Notes About Contact); SEP='.'; TLD=''
     LEAD='We design and maintain small, reliable systems &mdash; internal tools, data pipelines and the unglamorous plumbing that keeps them running.'
     CTA='See recent work'; CTAH='/work'
     CT=('Internal tooling' 'Data plumbing' 'Maintenance' 'Discovery' 'Handover' 'Reviews')
     CP=('Dashboards, admin panels and job runners that teams keep using after launch.'
         'Ingest, transform, schedule. Boring on purpose, observable by default.'
         'Long-term care for systems that outlived the team that wrote them.'
         'Two weeks of reading the code and the tickets before anyone estimates anything.'
         'Documentation and a walkthrough, so the work does not leave with us.'
         'A second pair of eyes on a design, an outage or a bill that keeps growing.')
     SB=("$YEAR" "$N2" '6' "$N1"); SL=('Working since' 'Projects shipped' 'People' 'Releases')
     F1=/privacy; F1T=Privacy; F2=/contact; F2T=Contact ;;
  1) NAVW=(Docs Pricing Changelog Status); SEP='/'; TLD='api'
     LEAD='A small HTTP API for queueing and running deferred jobs. No agents, no sidecars &mdash; one endpoint and a token.'
     CTA='Read the docs'; CTAH='/docs'
     CT=('Simple by design' 'Retries built in' 'Observable' 'Scheduling' 'Quotas' 'Webhooks')
     CP=('One POST creates a job. One GET tells you how it went. That is the whole surface.'
         'Exponential backoff, dead-letter queue, idempotency keys. Nothing to configure.'
         'Structured logs and per-job timing out of the box.'
         'Cron expressions or a delay in seconds, whichever fits the caller.'
         'Per-token rate limits, so one noisy client cannot starve the rest.'
         'Delivery with signatures and replay, for callers that would rather be told.')
     SB=("v2.$(( N2 % 9 ))" '99.9%' "&lt;$(( 55 + N2 % 45 ))ms" "$N1")
     SL=('Current release' 'Target uptime' 'Median enqueue' 'Regions')
     F1=/status; F1T=Status; F2=/terms; F2T=Terms ;;
  2) NAVW=(Archive Tags About Feed); SEP='.'; TLD=''
     LEAD='Occasional write-ups about builds, failures and the things that only break in production.'
     CTA='Browse the archive'; CTAH='/archive'
     CT=('Rewriting the scheduler' 'Notes on log retention' 'A postmortem, honestly'
         'The index we forgot' 'Cutting the build in half' 'On calling it done')
     CP=('Why we dropped the queue library and wrote 200 lines instead.'
         'Keeping 90 days without paying for 90 days.'
         'Four hours down, one missing index.'
         'A query that was fast until the table was not small.'
         'Most of it was waiting on a cache that never hit.'
         'The last ten percent, and why it took as long as the rest.')
     SB=("$N1" "$YEAR" 'RSS' "$N2"); SL=('Posts' 'First entry' 'Always on' 'Drafts')
     F1=/feed.xml; F1T=RSS; F2=/contact; F2T=Contact ;;
  *) NAVW=(Guides Reference FAQ Support); SEP='&middot;'; TLD=docs
     LEAD='Setup guides, reference material and the answers we got tired of repeating in chat.'
     CTA='Start here'; CTAH='/guides/getting-started'
     CT=('Getting started' 'Configuration' 'Troubleshooting' 'Upgrading' 'Recipes' 'Glossary')
     CP=('Install, configure, run your first task in about ten minutes.'
         'Every option, what it defaults to, and when you should not touch it.'
         'Common failures and how to read the logs when things go sideways.'
         'What changed, what breaks, and the order to do it in.'
         'Short worked examples for the things people ask about most.'
         'The words we use, and what we mean by them.')
     SB=("$N1+" 'Weekly' 'MIT' "$N2"); SL=('Pages' 'Updated' 'Licence' 'Contributors')
     F1=/changelog; F1T=Changelog; F2=/contact; F2T=Contact ;;
esac

{
  echo '<!doctype html><html lang="en"><head><meta charset="utf-8">'
  echo '<meta name="viewport" content="width=device-width,initial-scale=1">'
  echo "<title>$BN &mdash; $BT</title><meta name=\"description\" content=\"$BT\">"
  echo '<style>'
  echo ":root{--a:$BC;--ink:#1c1f23;--m:#5d6672;--l:#e4e7eb;--s:#f6f7f9}"
  echo '*{box-sizing:border-box;margin:0;padding:0}'
  echo "body{font:${BASE}px/1.65 $FSTACK;color:var(--ink);background:#fff}"
  echo 'a{color:var(--a);text-decoration:none}a:hover{text-decoration:underline}'
  echo ".$W{max-width:${MAXW}px;margin:0 auto;padding:0 24px}"
  echo 'header{border-bottom:1px solid var(--l);padding:18px 0}'
  echo ".$NAVC{display:flex;align-items:center;justify-content:space-between}"
  echo ".$BR{font-weight:650;font-size:17px}.$BR span{color:var(--a)}"
  echo 'nav ul{display:flex;gap:22px;list-style:none;font-size:14px}nav a{color:var(--m)}'
  echo ".$HERO{padding:${PADY}px 0 $(( PADY - 16 ))px;border-bottom:1px solid var(--l)}"
  echo ".$HERO h1{font-size:${H1}px;line-height:1.2;letter-spacing:-.6px;max-width:640px}"
  echo ".$HERO p{color:var(--m);margin-top:16px;max-width:560px}"
  echo ".$BTN{display:inline-block;margin-top:28px;background:var(--a);color:#fff;padding:10px 18px;border-radius:$R;font-size:14px}"
  echo ".$GR{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:28px;padding:${PADY}px 0}"
  echo ".$CD h3{font-size:16px;margin-bottom:8px}.$CD p{color:var(--m);font-size:14px}"
  echo ".$SP{background:var(--s);border-top:1px solid var(--l);border-bottom:1px solid var(--l);padding:40px 0}"
  echo ".$SP .$W{display:flex;flex-wrap:wrap;gap:40px}"
  echo ".$ST b{display:block;font-size:24px}.$ST span{color:var(--m);font-size:13px}"
  echo ".$FT{padding:36px 0;color:var(--m);font-size:13px;display:flex;justify-content:space-between;flex-wrap:wrap;gap:12px}"
  echo "@media(max-width:640px){.$HERO h1{font-size:$(( H1 - 9 ))px}nav ul{display:none}}"
  echo '</style></head><body>'

  echo "<header><div class=\"$W $NAVC\"><div class=\"$BR\">$BN<span>$SEP</span>$TLD</div>"
  printf '<nav><ul>'
  for ((i = 0; i < NNAV; i++)); do
    printf '<li><a href="/%s">%s</a></li>' "${NAVW[$i],,}" "${NAVW[$i]}"
  done
  echo '</ul></nav></div></header>'

  echo "<section class=\"$HERO\"><div class=\"$W\"><h1>$BT</h1><p>$LEAD</p>"
  echo "<a class=\"$BTN\" href=\"$CTAH\">$CTA</a></div></section>"

  echo "<div class=\"$W\"><div class=\"$GR\">"
  for ((i = 0; i < NCARD; i++)); do
    echo "<div class=\"$CD\"><h3>${CT[$i]}</h3><p>${CP[$i]}</p></div>"
  done
  echo '</div></div>'

  echo "<div class=\"$SP\"><div class=\"$W\">"
  for ((i = 0; i < NSTAT; i++)); do
    echo "<div class=\"$ST\"><b>${SB[$i]}</b><span>${SL[$i]}</span></div>"
  done
  echo '</div></div>'

  echo "<div class=\"$W\"><footer class=\"$FT\"><div>&copy; 2026 $BN</div><div><a href=\"$F1\">$F1T</a> &middot; <a href=\"$F2\">$F2T</a></div></footer></div>"
  echo '</body></html>'
} > /var/www/html/index.html
grn "  static site: $BN (layout $LAYOUT, accent $BC)"

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
# Two ways to get one, chosen with --cert-mode:
#
#   http (default)   certbot --standalone, one certificate per node, named after
#                    the node. Self-contained, needs nothing but port 80 — and
#                    every issuance publishes the node's hostname to the
#                    Certificate Transparency logs, where anyone can read it.
#
#   dns              one wildcard for *.<apex>, shared by every node. CT then
#                    shows the wildcard and nothing else, so node hostnames stop
#                    being enumerable from crt.sh. Validated over DNS-01 against
#                    the Gcore API, so the apex zone has to live in Gcore.
#
# Let's Encrypt allows five identical certificates per week, which is fewer than
# the fleet, so the nodes cannot each issue the same wildcard. One host issues
# and the others import: `rr cert-export` there, `--cert-bundle` here.
#
# Runs after the firewall opened :80 and before nginx is (re)started, because
# --standalone needs that port to itself.

cert_ok() {
  local n="$1" want="$2" f="/etc/letsencrypt/live/$1/fullchain.pem"
  [ -f "$f" ] || return 1
  openssl x509 -in "$f" -noout -checkend 604800 >/dev/null 2>&1 || return 1   # >7 days left
  # -F, not a regex: the wildcard name starts with a character grep would eat.
  openssl x509 -in "$f" -noout -text 2>/dev/null | grep -qF "DNS:$want" || return 1
}

install_bundle() {
  local b="$1"
  [ -f "$b" ] || die "certificate bundle not found: $b"
  mkdir -p /etc/letsencrypt/live
  tar -xzf "$b" -C /etc/letsencrypt/live 2>/dev/null || die "cannot unpack $b"
  cert_ok "$CERTNAME" "$CERTWANT" || die "the bundle in $b does not contain a valid certificate for $CERTWANT"
  grn "  certificate: imported from $b"
}

write_gcore_hook() {
  cat > "$HOOKF" <<'GCORE_HOOK'
#!/usr/bin/env bash
# ACME DNS-01 hook for Gcore. certbot calls it as `hook auth` and `hook cleanup`
# with CERTBOT_DOMAIN and CERTBOT_VALIDATION in the environment.
#
# A wildcard order asks for *.example.com and example.com, and both challenges
# answer on the same _acme-challenge.example.com. The second value has to be
# added to the first, never replace it, or the earlier authorization fails.
#
# The token is read from the environment when present and from disk otherwise,
# because renewal runs from a systemd timer that carries none of our variables.
set -uo pipefail
API="https://api.gcore.com/dns/v2"
TOKEN="${GCORE_API_TOKEN:-}"
[ -n "$TOKEN" ] && : || TOKEN=$(cat /opt/remnanode/.gcore-token 2>/dev/null || true)
[ -n "$TOKEN" ] || { echo "no Gcore API token in GCORE_API_TOKEN or /opt/remnanode/.gcore-token" >&2; exit 1; }

RESP=""; CODE=""
api() {
  local m="$1" p="$2" b="${3:-}" out
  if [ -n "$b" ]; then
    out=$(curl -sS --max-time 30 -X "$m" "$API/$p" -H "Authorization: APIKey $TOKEN" \
               -H 'Content-Type: application/json' -d "$b" -w '\n%{http_code}' 2>/dev/null)
  else
    out=$(curl -sS --max-time 30 -X "$m" "$API/$p" -H "Authorization: APIKey $TOKEN" \
               -w '\n%{http_code}' 2>/dev/null)
  fi
  CODE=$(printf '%s' "$out" | tail -n1)
  RESP=$(printf '%s' "$out" | sed '$d')
}

D="${CERTBOT_DOMAIN:-}"; V="${CERTBOT_VALIDATION:-}"
[ -n "$D" ] || { echo "CERTBOT_DOMAIN is empty" >&2; exit 1; }
REC="_acme-challenge.$D"

# Walk the labels upward until Gcore recognises one as a zone.
ZONE=""; c="$D"
while [ -n "$c" ]; do
  api GET "zones/$c"
  if [ "$CODE" = "200" ]; then ZONE="$c"; break; fi
  case "$c" in *.*) c="${c#*.}" ;; *) c="" ;; esac
done
[ -n "$ZONE" ] || { echo "no Gcore zone covers $D" >&2; exit 1; }

api GET "zones/$ZONE/$REC/TXT"
EXISTS=0; [ "$CODE" = "200" ] && EXISTS=1
CURRENT=$(printf '%s' "$RESP" | tr '}' '\n' | sed -n 's/.*"content":\["\([^"]*\)".*/\1/p')

payload() {   # values on stdin -> rrset JSON
  local out="" first=1 v
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    [ "$first" = 1 ] || out="$out,"
    out="$out{\"content\":[\"$v\"],\"enabled\":true}"
    first=0
  done
  printf '{"ttl":120,"resource_records":[%s]}' "$out"
}

case "${1:-auth}" in
  auth)
    WANT=$(printf '%s\n%s\n' "$CURRENT" "$V" | sed '/^$/d' | sort -u)
    BODY=$(printf '%s\n' "$WANT" | payload)
    if [ "$EXISTS" = 1 ]; then api PUT "zones/$ZONE/$REC/TXT" "$BODY"
    else                        api POST "zones/$ZONE/$REC/TXT" "$BODY"; fi
    case "$CODE" in 2*) : ;; *) echo "Gcore rejected the record ($CODE): $RESP" >&2; exit 1 ;; esac
    # Wait for it to be visible publicly. certbot validates for real afterwards,
    # so a timeout here is worth a warning and not an abort.
    for _ in $(seq 1 40); do
      if curl -s --max-time 10 -H 'accept: application/dns-json' \
              "https://dns.google/resolve?name=$REC&type=TXT" 2>/dev/null | grep -qF "$V"; then
        exit 0
      fi
      sleep 5
    done
    echo "warning: $REC did not show up in public DNS within 200s, trying anyway" >&2
    ;;
  cleanup)
    [ "$EXISTS" = 1 ] || exit 0
    LEFT=$(printf '%s\n' "$CURRENT" | sed '/^$/d' | grep -vxF "$V" || true)
    if [ -z "$LEFT" ]; then
      api DELETE "zones/$ZONE/$REC/TXT"
    else
      api PUT "zones/$ZONE/$REC/TXT" "$(printf '%s\n' "$LEFT" | payload)"
    fi
    ;;
esac
exit 0
GCORE_HOOK
  chmod 700 "$HOOKF"
}

HOOKF="$DIR/acme-gcore.sh"

# Certificates left over from a previous domain: this node serves exactly one.
if [ "${KEEP_CERTS:-0}" != "1" ]; then
  for c in $(certbot certificates 2>/dev/null | sed -n 's/^[[:space:]]*Certificate Name:[[:space:]]*//p'); do
    [ "$c" = "$CERTNAME" ] && continue
    ylw "  certificate: removing stale cert for $c"
    certbot delete --cert-name "$c" --non-interactive >/dev/null 2>&1 || true
  done
fi

if [ "${FORCE_CERT:-0}" = "1" ] && [ -d "/etc/letsencrypt/live/$CERTNAME" ]; then
  ylw "  certificate: --force-cert given, dropping the existing one"
  certbot delete --cert-name "$CERTNAME" --non-interactive >/dev/null 2>&1 || true
  rm -rf "/etc/letsencrypt/live/$CERTNAME"
fi

if [ -n "${CERT_BUNDLE:-}" ]; then
  install_bundle "$CERT_BUNDLE"
elif cert_ok "$CERTNAME" "$CERTWANT"; then
  grn "  certificate: existing one is valid, reusing it"
elif [ "$CERT_MODE" = "dns" ]; then
  [ -n "${GCORE_TOKEN:-}" ] || { can_ask && ask "Gcore API token (DNS-01 validation)" GCORE_TOKEN "$RE_TOKEN"; }
  [ -n "${GCORE_TOKEN:-}" ] || die "--cert-mode dns needs a Gcore API token (--gcore-token, GCORE_API_TOKEN,
  or an existing /opt/remnanode/.gcore-token). Alternatively issue the wildcard on
  one host and bring it here with --cert-bundle."
  printf '%s\n' "$GCORE_TOKEN" > "$DIR/.gcore-token"
  chmod 600 "$DIR/.gcore-token"
  write_gcore_hook
  EMAILARG="--register-unsafely-without-email"
  [ -n "${EMAIL:-}" ] && EMAILARG="-m $EMAIL"
  GCORE_API_TOKEN="$GCORE_TOKEN" certbot certonly --manual --preferred-challenges dns \
      --manual-auth-hook "$HOOKF auth" --manual-cleanup-hook "$HOOKF cleanup" \
      --cert-name "$CERTNAME" -d "*.$APEX" -d "$APEX" \
      --agree-tos --non-interactive $EMAILARG >/dev/null 2>&1 || true
  cert_ok "$CERTNAME" "$CERTWANT" || die "could not obtain the wildcard for $CERTWANT.
  Check that $APEX is hosted in Gcore and the token may edit its records.
  Run the hook by hand to see the API's reply:
    CERTBOT_DOMAIN=$APEX CERTBOT_VALIDATION=test $HOOKF auth
  Let's Encrypt allows 5 identical certificates per week; if that is the limit
  you hit, issue on one host and import here with --cert-bundle."
  grn "  certificate: wildcard issued for $CERTWANT"
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
  cert_ok "$CERTNAME" "$CERTWANT" || die "could not obtain a certificate for $DOMAIN.
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

# ---------- 5b. certificate renewal ----------
# http mode leaves certbot set to --standalone, which wants :80 that nginx now
# holds, so renewal is converted to webroot and proved with a dry run.
# dns mode renews through the Gcore hook and needs neither.
RCONF="/etc/letsencrypt/renewal/${CERTNAME}.conf"
if [ ! -f "$RCONF" ]; then
  if [ -n "${CERT_BUNDLE:-}" ] || [ "$CERT_MODE" = "dns" ]; then
    ylw "  certificate: no renewal config here - this node runs on an imported bundle."
    ylw "              Renew on the issuing host and import again before it expires."
  else
    ylw "  certificate: renewal config not found, renewal not verified"
  fi
elif ! command -v certbot >/dev/null; then
  ylw "  certificate: certbot not found, renewal not verified"
elif grep -q '^authenticator[[:space:]]*=[[:space:]]*manual' "$RCONF"; then
  # A dry run here would drive two real challenges through the Gcore API and
  # wait on public DNS for both, which is minutes on every single run. Check
  # that the parts renewal depends on are present instead.
  if [ -s "$DIR/.gcore-token" ] && [ -x "$HOOKF" ]; then
    grn "  certificate: DNS-01 renewal configured (hook and token in place)"
  else
    red "  certificate: DNS-01 renewal will fail - hook or token missing under $DIR"
    red "              Re-run with --gcore-token to restore them."
  fi
elif grep -q '^authenticator[[:space:]]*=[[:space:]]*standalone' "$RCONF"; then
  cp "$RCONF" "${RCONF}.bak-$STAMP"
  sed -i -E 's|^authenticator[[:space:]]*=.*|authenticator = webroot|' "$RCONF"
  grep -q '^webroot_path' "$RCONF" && sed -i -E 's|^webroot_path[[:space:]]*=.*|webroot_path = /var/www/html,|' "$RCONF" || sed -i -E '/^authenticator = webroot/a webroot_path = /var/www/html,' "$RCONF"
  if certbot renew --cert-name "$CERTNAME" --dry-run >/dev/null 2>&1; then
    grn "  certificate: renewal switched to webroot, dry run passed"
  else
    cp "${RCONF}.bak-$STAMP" "$RCONF"
    red "  certificate: webroot failed, reverted to standalone."
    red "              Renewal now conflicts with nginx on :80 - fix this manually!"
  fi
else
  if certbot renew --cert-name "$CERTNAME" --dry-run >/dev/null 2>&1; then
    grn "  certificate: renewal works"
  else
    ylw "  certificate: renewal dry run failed - check 'certbot renew --dry-run'"
  fi
fi

# ---------- 6. keys and panel values ----------
KEYS=$(docker exec remnanode xray x25519 2>/dev/null || true)
PRIV=$(printf '%s' "$KEYS" | grep -i 'private' | awk '{print $NF}' || true)
PUB=$(printf '%s' "$KEYS" | grep -i 'public' | awk '{print $NF}' || true)
SID=$(openssl rand -hex 8)
SALT=$(openssl rand -hex 32)
SUF=$(printf '%s' "$DOMAIN" | md5sum | cut -c1-4 | tr 'a-z' 'A-Z')
PATHS=("/api/collect/" "/assets/live/" "/media/segments/" "/v1/events/" "/static/chunks/" "/api/feed/" "/data/sync/" "/pub/updates/")
XPATH="${PATHS[$(( $(hb 40) % ${#PATHS[@]} ))]}"
SEQ=$(tr -dc 'a-z' </dev/urandom | head -c1 || true)
SES=$(tr -dc 'a-z' </dev/urandom | head -c1 || true)
# The User-Agent Xray wants here is a KEYWORD, not a header value. The core
# knows chrome, firefox, safari, edge, curl and golang, and expands each into a
# full matching set - the real UA plus sec-ch-ua, Accept, Accept-Language and
# sec-fetch-* (common/utils/browser.go, TryDefaultHeadersWith). A hand-written
# "Mozilla/5.0 ..." string matches no case, so none of the companion headers are
# set at all and the request resembles a browser in exactly one field out of
# seven. The literal is worse than the short word, not better.
#
# It also has to equal the REALITY fingerprint, or uTLS presents itself as one
# browser while the headers claim another. Both read from FP for that reason.
# Only these four are valid on both sides, and the seed picks one so the fleet
# is not uniform while a given node stays stable across re-runs.
FPS=(chrome firefox safari edge)
FP="${FPS[$(( $(hb 41) % 4 ))]}"
UA="$FP"
SESSTAB="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
CERTF="/etc/letsencrypt/live/$CERTNAME/fullchain.pem"
KEYF="/etc/letsencrypt/live/$CERTNAME/privkey.pem"
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
  echo "          \"fingerprint\": \"$FP\", \"spiderX\": \"/\" }"
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
  echo "Fingerprint: $FP        <- must match the User-Agent keyword below"
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
  echo
  echo "--- masquerade site ---"
  echo "Brand              : $BN"
  echo "Accent             : $BC"
  echo "Seed               : $SEEDF (delete or pass --new-site to reroll)"
} > "$OUT"
chmod 600 "$OUT"

# ---------- 7. install as `rr` for quick re-runs ----------
# Fetched fresh rather than copied from $0: under bash <(curl ...) the script
# arrives on a pipe that has already been consumed and cannot be read again.
# Syntax-checked before it replaces anything, so a truncated download cannot
# leave a broken command behind.
# The query string is a cache-buster: the raw CDN serves a stale copy for some
# minutes after a push, so installing rr right after an update would otherwise
# fetch the previous version and report success.
RAW_URL="https://raw.githubusercontent.com/pret3nder/edge-bootstrap/master/node-setup.sh"
if command -v curl >/dev/null; then
  if curl -fsSL --max-time 20 "$RAW_URL?$(date +%s)" -H "Cache-Control: no-cache" -o /usr/local/bin/.rr.tmp 2>/dev/null \
     && bash -n /usr/local/bin/.rr.tmp 2>/dev/null \
     && grep -q '^# EOF-MARKER:' /usr/local/bin/.rr.tmp \
     && grep -q '^cmd_cert_export()' /usr/local/bin/.rr.tmp; then
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
  # Another installer may already own the name. A shell alias beats $PATH, and
  # aliases are not visible from a non-interactive shell, so the rc files are
  # read directly rather than asking the shell. Without this the script would
  # report "installed as rr" while typing rr ran something else entirely.
  RRA=$(grep -rhoE "^[[:space:]]*alias[[:space:]]+rr=.*" \
        "$HOME/.bashrc" "$HOME/.bash_aliases" /root/.bashrc /etc/bash.bashrc \
        /etc/profile.d/*.sh 2>/dev/null | head -1 || true)
  RRP=$(command -v rr 2>/dev/null || true)
  if [ -n "$RRA" ]; then
    ylw "Installed at /usr/local/bin/rr, but 'rr' is a shell alias on this host:"
    ylw "  $RRA"
    ylw "An alias wins over PATH, so use the full path or remove it:"
    echo "  /usr/local/bin/rr $DOMAIN"
    echo "  grep -rn 'alias rr=' ~/.bashrc ~/.bash_aliases /etc/profile.d/ 2>/dev/null"
  elif [ -n "$RRP" ] && [ "$RRP" != "/usr/local/bin/rr" ]; then
    ylw "Installed at /usr/local/bin/rr, but another rr comes first in PATH: $RRP"
    echo "  run it as:  /usr/local/bin/rr $DOMAIN"
  else
    grn "Installed as 'rr' - re-run on this host with:  rr $DOMAIN"
  fi
fi

# EOF-MARKER: the last line of this file. The rr installer checks for it, since
# a download truncated at a syntactically complete point still passes bash -n,
# and a copy missing its tail dispatches to functions that are no longer there.
