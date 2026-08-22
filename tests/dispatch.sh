#!/usr/bin/env bash
# Проверяет, что подкоманды не проваливаются в setup и что check ничего не меняет.
set -u
T=$(mktemp -d); export PATH="$T/bin:$PATH"
mkdir -p "$T/bin" "$T/opt/remnanode" "$T/etc/letsencrypt/live/n.example.com" \
         "$T/etc/letsencrypt/renewal" "$T/var/www/html" "$T/root"

cat > "$T/opt/remnanode/docker-compose.yml" <<EOF
services:
  remnawave-nginx:
    volumes:
      - $T/etc/letsencrypt/live/n.example.com/fullchain.pem:/etc/nginx/ssl/n.example.com/fullchain.pem:ro
  remnanode:
    image: remnawave/node:2.8.0
    volumes:
      - $T/etc/letsencrypt:/etc/letsencrypt:ro
      - /dev/shm:/dev/shm:rw
EOF
printf 'server {\n    server_name n.example.com;\n    server_tokens off;\n}\n' > "$T/opt/remnanode/nginx.conf"
printf '<title>Kestrel</title>' > "$T/var/www/html/index.html"
printf 'authenticator = webroot\n' > "$T/etc/letsencrypt/renewal/n.example.com.conf"
: > "$T/etc/letsencrypt/live/n.example.com/fullchain.pem"
printf 'PANEL DATA OK\n' > "$T/root/n.example.com-panel.txt"

cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  inspect) echo running ;;
  logs)    echo "[init-env] Xray version: Xray 26.6.27 (Xray) x (go1.26 linux/amd64)" ;;
  exec)    exit 0 ;;
  *)       exit 0 ;;
esac
EOF
cat > "$T/bin/ufw" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "status" ] && printf 'Status: active\n[ 1] 22/tcp ALLOW IN Anywhere\n[ 2] 443/tcp ALLOW IN Anywhere\n[ 3] 2222/tcp ALLOW IN 10.0.0.1\n'
exit 0
EOF
cat > "$T/bin/ss" <<'EOF'
#!/usr/bin/env bash
printf 'State Recv-Q Send-Q Local:Port Peer\nLISTEN 0 511 *:443 *:*\nLISTEN 0 511 *:2222 *:*\nLISTEN 0 511 *:80 *:*\n'
EOF
cat > "$T/bin/openssl" <<'EOF'
#!/usr/bin/env bash
case "$*" in *-enddate*) echo "notAfter=Dec 31 23:59:59 2026 GMT" ;; *) echo x ;; esac
EOF
cat > "$T/bin/certbot" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$T/bin/"*

S="$T/run.sh"
sed -e "s|^DIR=\"/opt/remnanode\"|DIR=\"$T/opt/remnanode\"|" \
    -e "s|/etc/letsencrypt|$T/etc/letsencrypt|g" \
    -e "s|/var/www/html|$T/var/www/html|g" \
    -e "s|\"/root/|\"$T/root/|g" \
    -e 's|^\[ "$(id -u)" = "0" \] .*|:|' \
    node-setup.sh > "$S"

fail=0
mark() { cp -r "$T/opt/remnanode" "$T/snapshot"; }
changed() { diff -r "$T/opt/remnanode" "$T/snapshot" >/dev/null 2>&1 && echo no || echo yes; }

echo "=== check ==="
mark
OUT=$(bash "$S" check 2>&1); RC=$?
echo "$OUT" | sed 's/^/  /'
echo "  код: $RC   изменил файлы: $(changed)"
[ "$RC" = "0" ] || { echo "  ⚠ check вернул $RC"; fail=1; }
[ "$(changed)" = "no" ] || { echo "  ⚠ check ИЗМЕНИЛ файлы (должен быть read-only)"; fail=1; }
echo "$OUT" | grep -q "hardened nginx config written" && { echo "  ⚠ check провалился в setup"; fail=1; }
rm -rf "$T/snapshot"

echo
echo "=== panel ==="
OUT=$(bash "$S" panel 2>&1); RC=$?
echo "$OUT" | sed 's/^/  /'
[ "$RC" = "0" ] && echo "$OUT" | grep -q "PANEL DATA OK" || { echo "  ⚠ panel не отдал данные"; fail=1; }
echo "$OUT" | grep -q "hardened nginx" && { echo "  ⚠ panel провалился в setup"; fail=1; }

echo
echo "=== cert-export ==="
# Повод: cmd_cert_export оказалась вложена ВНУТРЬ install_node(). Файл при этом
# парсился, диспетчер её вызывал, а определялась она только после запуска
# установки - на живой ноде это "cmd_cert_export: command not found".
OUT=$(bash "$S" cert-export 2>&1); RC=$?
echo "$OUT" | sed 's/^/  /'
[ "$RC" = "0" ] || { echo "  ⚠ cert-export вернул $RC"; fail=1; }
echo "$OUT" | grep -q 'command not found' && { echo "  ⚠ функция не определена на момент вызова"; fail=1; }
B=$(ls "$T"/root/*.tgz 2>/dev/null | head -1)
if [ -n "$B" ] && [ -s "$B" ]; then
  echo "  ✓ бандл собран: $(basename "$B")"
  tar -tzf "$B" >/dev/null 2>&1 && echo "  ✓ это валидный tar.gz" || { echo "  ⚠ архив битый"; fail=1; }
else
  echo "  ⚠ бандл не создан"; fail=1
fi

echo
echo "=== все функции диспетчера определены до вызова ==="
for f in cmd_check cmd_panel cmd_cert_export menu install_node; do
  # Определение должно идти на верхнем уровне, а не быть вложенным в другую
  # функцию: проверяем, что строка начинается с самого начала строки.
  grep -qE "^$f\(\) \{" "$S" && echo "  ✓ $f" || { echo "  ⚠ $f не на верхнем уровне"; fail=1; }
done

echo
[ "$fail" = "0" ] && echo "ВСЕ ПРОВЕРКИ ПРОШЛИ" || echo "ЕСТЬ ПРОБЛЕМЫ"
rm -rf "$T"
exit $fail
