#!/usr/bin/env bash
# Установка на чистый сервер: /opt/remnanode пуст, докера "нет".
# Проверяем, что compose создаётся корректно и с нужными версиями.
set -u
T=$(mktemp -d); export PATH="$T/bin:$PATH"
mkdir -p "$T/bin" "$T/opt" "$T/etc/letsencrypt/renewal" "$T/var/www/html" "$T/root"

cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  compose) [ "${2:-}" = "version" ] && { echo "Docker Compose version v2.40.0"; exit 0; }; exit 0 ;;
  inspect) echo running ;;
  logs)    echo "[init-env] Xray version: Xray 26.6.27 (Xray) x (go1.26 linux/amd64)" ;;
  exec)    shift; case "$*" in *x25519*) printf 'PrivateKey: PRIVaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nPassword (PublicKey): PUBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;; *) exit 0 ;; esac ;;
  *) exit 0 ;;
esac
EOF
cat > "$T/bin/ufw" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "status" ] && printf 'Status: active\n[ 1] 22/tcp ALLOW IN Anywhere\n'
exit 0
EOF
cat > "$T/bin/certbot" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  certificates) : ;;
  certonly) mkdir -p "$LE/live/$TEST_DOMAIN"; : > "$LE/live/$TEST_DOMAIN/fullchain.pem"; : > "$LE/live/$TEST_DOMAIN/privkey.pem" ;;
esac
exit 0
EOF
cat > "$T/bin/openssl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "-checkend" ] && exit 0; done
case "$*" in *-text*) echo "        DNS:$TEST_DOMAIN" ;; *-enddate*) echo "notAfter=Dec 31 23:59:59 2026 GMT" ;; *) echo x ;; esac
EOF
cat > "$T/bin/ss" <<'EOF'
#!/usr/bin/env bash
printf 'State Recv-Q Send-Q Local Peer\nLISTEN 0 511 *:443 *:*\nLISTEN 0 511 *:2222 *:*\n'
EOF
cat > "$T/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$T/bin/"*

export LE="$T/etc/letsencrypt" TEST_DOMAIN="fresh.example.com"
KEY="eyJub2RlQ2VydFBlbSI6IkZBS0VLRVlGT1JURVNUSU5HMTIzNDU2Nzg5MEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoifQ=="

S="$T/run.sh"
sed -e "s|^DIR=\"/opt/remnanode\"|DIR=\"$T/opt/remnanode\"|" \
    -e "s|/etc/letsencrypt|$T/etc/letsencrypt|g" \
    -e "s|/var/www/html|$T/var/www/html|g" \
    -e "s|\"/root/|\"$T/root/|g" \
    -e "s|/usr/local/bin/|$T/bin/|g" \
    -e 's|^\[ "$(id -u)" = "0" \] .*|:|' \
    node-setup.sh > "$S"

echo "=== установка на чистый сервер ==="
bash "$S" "$TEST_DOMAIN" --secret-key "$KEY" --panel-ip 10.0.0.1 --email a@b.c 2>&1 | sed 's/^/  /'
RC=${PIPESTATUS[0]}
echo "  код: $RC"
echo

fail=0
C="$T/opt/remnanode/docker-compose.yml"
if [ ! -f "$C" ]; then
  echo "  ⚠ compose НЕ СОЗДАН"; fail=1
else
  echo "=== проверка созданного compose ==="
  for pair in "image: remnawave/node:2.8.0|пин версии ноды" \
              "image: nginx:1.28|nginx" \
              "SECRET_KEY=$KEY|ключ подставлен" \
              "letsencrypt:ro|монт сертов в remnanode" \
              "live/$TEST_DOMAIN/fullchain.pem|серт своего домена" \
              "NODE_PORT=2222|порт ноды" \
              "network_mode: host|сеть" \
              "max-size: 10m|лимит логов"; do
    pat="${pair%%|*}"; label="${pair#*|}"
    if grep -qF "$pat" "$C"; then echo "  ✓ $label"; else echo "  ⚠ НЕТ: $label"; fail=1; fi
  done
  # chmod is a no-op on some dev filesystems, so this is informational only.
  echo "  · режим файла: $(stat -c '%a' "$C" 2>/dev/null || echo "?") (на Linux ожидается 600)"
fi
[ -s "$T/opt/remnanode/nginx.conf" ] && echo "  ✓ nginx.conf создан" || { echo "  ⚠ нет nginx.conf"; fail=1; }
[ -s "$T/var/www/html/index.html" ] && echo "  ✓ заглушка создана" || { echo "  ⚠ нет заглушки"; fail=1; }
P="$T/root/$TEST_DOMAIN-panel.txt"
if [ -s "$P" ]; then
  echo "  ✓ данные для панели записаны"
  # User-Agent для XHTTP - это КЛЮЧЕВОЕ СЛОВО Xray, а не строка заголовка.
  # Ядро знает chrome/firefox/safari/edge/curl/golang и разворачивает каждое
  # в полный набор (sec-ch-ua, Accept, sec-fetch-*). Литерал "Mozilla/5.0 ..."
  # не подходит ни под один case - сопутствующие заголовки не ставятся вовсе.
  # Скрипт однажды генерировал именно литерал; это регрессия, а не мелочь.
  ua=$(grep -oE '"User-Agent": "[^"]*"' "$P" | head -1 | sed 's/.*: "//; s/"$//')
  # fingerprint клиентское поле: в серверном инбаунде его нет, берём из Host-блока XHTTP
  fp=$(grep -m1 '^Fingerprint: ' "$P" | awk '{print $2}')
  case "$ua" in
    chrome|firefox|safari|edge) echo "  ✓ User-Agent - ключевое слово: $ua" ;;
    Mozilla*) echo "  ⚠ User-Agent - ЛИТЕРАЛ ($(printf '%.40s' "$ua")...) - Xray его не развернёт"; fail=1 ;;
    *)        echo "  ⚠ User-Agent непонятного вида: '$ua'"; fail=1 ;;
  esac
  if [ -n "$fp" ] && [ "$fp" = "$ua" ]; then
    echo "  ✓ fingerprint совпадает с User-Agent: $fp"
  else
    echo "  ⚠ fingerprint='$fp' против User-Agent='$ua' - uTLS и заголовки разойдутся"; fail=1
  fi
  grep -q "Fingerprint: $fp" "$P" && echo "  ✓ в инструкции по Host тот же fingerprint" \
    || { echo "  ⚠ в инструкции по Host fingerprint другой"; fail=1; }
  # Парк целиком на firefox: хосты, fingerprint REALITY и User-Agent.
  [ "$fp" = firefox ] && [ "$ua" = firefox ] && echo "  ✓ fingerprint и User-Agent = firefox" \
    || { echo "  ⚠ ожидался firefox, а fp='$fp' ua='$ua'"; fail=1; }
  n=$(grep -c '^Fingerprint: ' "$P" || true); nf=$(grep -c '^Fingerprint: firefox' "$P" || true)
  [ "$n" -gt 0 ] && [ "$n" = "$nf" ] && echo "  ✓ во всех Host-блоках fingerprint firefox ($n)" \
    || { echo "  ⚠ Host-блоки с другим fingerprint: $((n - nf)) из $n"; fail=1; }
  # VLESS raw+REALITY на отдельном порту: 443/tcp занят XHTTP.
  grep -qE '"tag": "VLESS-REALITY-[0-9A-F]{4}", "port": 2083' "$P" && echo "  ✓ инбаунд VLESS-REALITY на 2083" \
    || { echo "  ⚠ нет инбаунда VLESS-REALITY на 2083"; fail=1; }
  grep -q '"network": "raw", "security": "reality"' "$P" && echo "  ✓ raw + reality" \
    || { echo "  ⚠ у VLESS-REALITY не raw+reality"; fail=1; }
  grep -q -- '--- Host: .* \[reality\] ---' "$P" && grep -q 'Address    : .* / 2083' "$P" \
    && echo "  ✓ инструкция по Host [Reality] на 2083" || { echo "  ⚠ нет Host-блока [Reality]"; fail=1; }
  grep -q 'REALITY 2083 privateKey' "$P" && echo "  ✓ отдельные ключи для 2083 записаны" \
    || { echo "  ⚠ нет ключей для 2083"; fail=1; }
  grep -q 'Trojan\|8443' "$P" && { echo "  ⚠ в профиле снова Trojan/8443"; fail=1; } || echo "  ✓ Trojan не генерируется"
  # Xray молча игнорирует неизвестные поля. finalmask.obfs в ядре нет и не было:
  # Salamander живёт в finalmask.udp[], и панель ищет там же - с obfs обе стороны
  # тихо работали голым QUIC. session*/seq* при stream-one не существуют вовсе.
  grep -q '"obfs"' "$P" && { echo "  ⚠ снова finalmask.obfs (Salamander выключен)"; fail=1; } || echo "  ✓ нет finalmask.obfs"
  s=$(grep -c '"udp": \[{ "type": "salamander", "settings": { "password": "' "$P" || true)
  [ "$s" = 2 ] && echo "  ✓ Salamander в finalmask.udp[] - в инбаунде и в Host" \
    || { echo "  ⚠ Salamander в udp[] найден $s раз, ожидалось 2 (инбаунд + Host)"; fail=1; }
  grep -qE '"(seqKey|seqPlacement|sessionKey|sessionPlacement|sessionTable|sessionLength|sessionID[A-Za-z]*)"' "$P" \
    && { echo "  ⚠ мёртвые session*/seq* при stream-one"; fail=1; } || echo "  ✓ нет мёртвых session*/seq*"
  grep -qE '"(spiderX|fingerprint)"' "$P" && { echo "  ⚠ клиентские поля REALITY в серверном инбаунде"; fail=1; } \
    || echo "  ✓ в серверном REALITY нет клиентских полей"
else
  echo "  ⚠ нет данных для панели"; fail=1
fi

echo
[ "$fail" = "0" ] && echo "ВСЕ ПРОВЕРКИ ПРОШЛИ" || echo "ЕСТЬ ПРОБЛЕМЫ"
rm -rf "$T"
exit $fail
