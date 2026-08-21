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
[ -s "$T/root/$TEST_DOMAIN-panel.txt" ] && echo "  ✓ данные для панели записаны" || { echo "  ⚠ нет данных для панели"; fail=1; }

echo
[ "$fail" = "0" ] && echo "ВСЕ ПРОВЕРКИ ПРОШЛИ" || echo "ЕСТЬ ПРОБЛЕМЫ"
rm -rf "$T"
exit $fail
