#!/usr/bin/env bash
# Режим --cert-mode dns.
#
# Главное, что здесь проверяется: заказ на wildcard даёт ДВА challenge на одно
# и то же имя _acme-challenge.<apex> (для *.apex и для самого apex). Второй hook
# обязан ДОБАВИТЬ значение к первому. Если он его перезапишет, первая
# авторизация отвалится, и выпуск сломается ровно на wildcard.
set -u
T=$(mktemp -d); export PATH="$T/bin:$PATH"
mkdir -p "$T/bin" "$T/opt/remnanode" "$T/etc/letsencrypt/renewal" "$T/var/www/html" "$T/root"
fail=0

# ---------- часть 1: hook против поддельного API Gcore ----------
sed -n '/cat > "\$HOOKF" <<.GCORE_HOOK./,/^GCORE_HOOK$/p' node-setup.sh | sed '1d;$d' > "$T/hook.sh"
chmod +x "$T/hook.sh"
[ -s "$T/hook.sh" ] || { echo "  ⚠ не удалось извлечь hook из скрипта"; rm -rf "$T"; exit 1; }
bash -n "$T/hook.sh" || { echo "  ⚠ hook не парсится"; rm -rf "$T"; exit 1; }

cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
M=GET; URL=""; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) shift; M="$1" ;;
    -d) shift; BODY="$1" ;;
    http://*|https://*) URL="$1" ;;
  esac
  shift
done
S="$STATE"
case "$URL" in
  *dns.google*) cat "$S" 2>/dev/null; exit 0 ;;
  */TXT)
    case "$M" in
      GET)      if [ -f "$S" ]; then cat "$S"; echo; echo 200; else echo '{"error":"not found"}'; echo 404; fi ;;
      POST|PUT) printf '%s' "$BODY" > "$S"; echo '{"ok":true}'; echo 200 ;;
      DELETE)   rm -f "$S"; echo '{"ok":true}'; echo 200 ;;
    esac
    exit 0 ;;
  */zones/example.com) echo '{"name":"example.com"}'; echo 200; exit 0 ;;
  *)                   echo '{"error":"no zone"}'; echo 404; exit 0 ;;
esac
EOF
chmod +x "$T/bin/curl"
export STATE="$T/rrset.json" GCORE_API_TOKEN=testtoken

echo "=== hook: два challenge на одно имя ==="
CERTBOT_DOMAIN=example.com CERTBOT_VALIDATION=VALUE-ONE bash "$T/hook.sh" auth >/dev/null 2>&1
rc1=$?
CERTBOT_DOMAIN=example.com CERTBOT_VALIDATION=VALUE-TWO bash "$T/hook.sh" auth >/dev/null 2>&1
rc2=$?
body=$(cat "$STATE" 2>/dev/null)
echo "  запись после двух auth: $body"
[ "$rc1" = "0" ] && [ "$rc2" = "0" ] || { echo "  ⚠ auth вернул $rc1/$rc2"; fail=1; }
if printf '%s' "$body" | grep -q 'VALUE-ONE' && printf '%s' "$body" | grep -q 'VALUE-TWO'; then
  echo "  ✓ оба значения на месте (второй не затёр первый)"
else
  echo "  ⚠ ПОТЕРЯНО значение - wildcard так не выпустится"; fail=1
fi

echo
echo "=== hook: cleanup убирает только своё ==="
CERTBOT_DOMAIN=example.com CERTBOT_VALIDATION=VALUE-ONE bash "$T/hook.sh" cleanup >/dev/null 2>&1
body=$(cat "$STATE" 2>/dev/null)
echo "  осталось: $body"
if printf '%s' "$body" | grep -q 'VALUE-TWO' && ! printf '%s' "$body" | grep -q 'VALUE-ONE'; then
  echo "  ✓ удалено ровно одно значение"
else
  echo "  ⚠ cleanup сработал неверно"; fail=1
fi
CERTBOT_DOMAIN=example.com CERTBOT_VALIDATION=VALUE-TWO bash "$T/hook.sh" cleanup >/dev/null 2>&1
[ -f "$STATE" ] && { echo "  ⚠ пустой rrset не удалён"; fail=1; } || echo "  ✓ пустой rrset удалён целиком"

echo
echo "=== hook: без токена не работает молча ==="
out=$(env -u GCORE_API_TOKEN CERTBOT_DOMAIN=example.com CERTBOT_VALIDATION=X bash "$T/hook.sh" auth 2>&1); rc=$?
[ "$rc" != "0" ] && echo "  ✓ выход $rc: $(printf '%s' "$out" | head -1)" || { echo "  ⚠ без токена вернул 0"; fail=1; }

# ---------- часть 2: имя сертификата протянуто везде ----------
echo
echo "=== dns-режим: apex вместо имени ноды ==="
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  compose) [ "${2:-}" = "version" ] && { echo "Docker Compose version v2.40.0"; exit 0; }; exit 0 ;;
  inspect) echo running ;;
  logs)    echo "[init-env] Xray version: Xray 26.6.27 (Xray) x (go1.26 linux/amd64)" ;;
  exec)    shift; case "$*" in *x25519*) printf 'PrivateKey: PRIVaaaa\nPassword (PublicKey): PUBbbbb\n' ;; *) exit 0 ;; esac ;;
  *) exit 0 ;;
esac
EOF
cat > "$T/bin/certbot" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  certificates) : ;;
  certonly)
    mkdir -p "$LE/live/example.com"
    : > "$LE/live/example.com/fullchain.pem"; : > "$LE/live/example.com/privkey.pem"
    printf 'authenticator = manual\n' > "$LE/renewal/example.com.conf" ;;
esac
exit 0
EOF
cat > "$T/bin/openssl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "-checkend" ] && exit 0; done
case "$*" in
  *-text*)    echo "        DNS:*.example.com, DNS:example.com" ;;
  *-enddate*) echo "notAfter=Dec 31 23:59:59 2026 GMT" ;;
  *rand*)     head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' ;;
  *) echo x ;;
esac
EOF
for s in ufw ss apt-get systemctl; do printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/$s"; done
printf '#!/usr/bin/env bash\n[ "${1:-}" = "status" ] && printf "Status: active\\n[ 1] 22/tcp ALLOW IN Anywhere\\n"\nexit 0\n' > "$T/bin/ufw"
printf '#!/usr/bin/env bash\nprintf "LISTEN 0 511 *:443 *:*\\n"\n' > "$T/bin/ss"
chmod +x "$T/bin/"*
export LE="$T/etc/letsencrypt"
KEY="eyJub2RlQ2VydFBlbSI6IkZBS0VLRVlGT1JURVNUSU5HMTIzNDU2Nzg5MEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaIn0="

S="$T/run.sh"
sed -e "s|^DIR=\"/opt/remnanode\"|DIR=\"$T/opt/remnanode\"|" \
    -e "s|/etc/letsencrypt|$T/etc/letsencrypt|g" \
    -e "s|/var/www/html|$T/var/www/html|g" \
    -e "s|\"/root/|\"$T/root/|g" \
    -e "s|/usr/local/bin/|$T/bin/|g" \
    -e 's|^\[ "$(id -u)" = "0" \] .*|:|' \
    node-setup.sh > "$S"

bash "$S" node.example.com --cert-mode dns --gcore-token tok \
     --secret-key "$KEY" --panel-ip 10.0.0.1 --email a@b.c >"$T/out.log" 2>&1
echo "  код: $?"
C="$T/opt/remnanode/docker-compose.yml"
for pair in "live/example.com/fullchain.pem|compose монтирует wildcard, а не имя ноды" \
            "ssl/example.com/fullchain.pem|путь внутри контейнера тоже apex"; do
  pat="${pair%%|*}"; label="${pair#*|}"
  grep -qF "$pat" "$C" 2>/dev/null && echo "  ✓ $label" || { echo "  ⚠ НЕТ: $label"; fail=1; }
done
grep -qF 'ssl_certificate         "/etc/nginx/ssl/example.com/fullchain.pem"' "$T/opt/remnanode/nginx.conf" 2>/dev/null \
  && echo "  ✓ nginx ссылается на wildcard" || { echo "  ⚠ nginx не переключился на wildcard"; fail=1; }
grep -q 'server_name node.example.com;' "$T/opt/remnanode/nginx.conf" 2>/dev/null \
  && echo "  ✓ server_name остался доменом ноды" || { echo "  ⚠ server_name съехал"; fail=1; }
[ -x "$T/opt/remnanode/acme-gcore.sh" ] && echo "  ✓ hook установлен" || { echo "  ⚠ hook не записан"; fail=1; }
if [ -s "$T/opt/remnanode/.gcore-token" ]; then
  m=$(stat -c '%a' "$T/opt/remnanode/.gcore-token" 2>/dev/null || echo "?")
  echo "  ✓ токен сохранён для автопродления (режим $m, на Linux ожидается 600)"
else
  echo "  ⚠ токен не сохранён - продление по таймеру не сработает"; fail=1
fi

# ---------- часть 3: импорт бандла (этот путь пройдут все ноды кроме одной) ----------
echo
echo "=== --cert-bundle: установка готового wildcard ==="
B="$T/bundle"; mkdir -p "$B/example.com"
printf 'CERT\n' > "$B/example.com/fullchain.pem"; printf 'KEY\n' > "$B/example.com/privkey.pem"
tar -czf "$T/wc.tgz" -C "$B" example.com 2>/dev/null || { echo "  ⚠ не собрать тестовый бандл"; fail=1; }
rm -rf "$T/etc/letsencrypt/live" "$T/etc/letsencrypt/renewal/example.com.conf"
out=$(bash "$S" node2.example.com --cert-mode dns --cert-bundle "$T/wc.tgz" \
        --secret-key "$KEY" --panel-ip 10.0.0.1 2>&1); rc=$?
echo "  код: $rc"
printf '%s' "$out" | grep -q 'imported from' && echo "  ✓ бандл принят" || { echo "  ⚠ бандл не установлен"; fail=1; }
[ -f "$T/etc/letsencrypt/live/example.com/fullchain.pem" ] \
  && echo "  ✓ файлы на месте" || { echo "  ⚠ файлов нет"; fail=1; }
printf '%s' "$out" | grep -q 'imported bundle' \
  && echo "  ✓ предупреждение про продление на другом хосте выдано" \
  || { echo "  ⚠ про продление ничего не сказано"; fail=1; }

echo
echo "=== --cert-bundle: битый бандл не проходит молча ==="
printf 'garbage' > "$T/bad.tgz"
out=$(bash "$S" node3.example.com --cert-mode dns --cert-bundle "$T/bad.tgz" \
        --secret-key "$KEY" --panel-ip 10.0.0.1 2>&1); rc=$?
[ "$rc" != "0" ] && echo "  ✓ выход $rc: $(printf '%s' "$out" | grep -i 'cannot unpack\|does not contain' | head -1)" \
  || { echo "  ⚠ битый бандл принят"; fail=1; }

echo
[ "$fail" = "0" ] && echo "ВСЕ ПРОВЕРКИ ПРОШЛИ" || echo "ЕСТЬ ПРОБЛЕМЫ"
rm -rf "$T"
exit $fail
