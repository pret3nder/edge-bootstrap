#!/usr/bin/env bash
# Нода упала и сама не поднялась. Проверяем все четыре причины, из-за которых
# "restart: always" в compose ничего не гарантирует:
#   1) демон docker не включён в автозагрузку;
#   2) в чужом compose политика слабее (unless-stopped / on-failure / no);
#   3) политика в файле не применяется к уже созданному контейнеру;
#   4) удалённый контейнер не поднимет никакая политика - нужен таймер.
set -u
T=$(mktemp -d); export PATH="$T/bin:$PATH"
mkdir -p "$T/bin" "$T/opt/remnanode" "$T/etc/systemd/system" "$T/var/www/html" "$T/root" \
         "$T/etc/letsencrypt/live/n.example.com"

# Чужой compose: политика слабее нужной, якорей нет.
cat > "$T/opt/remnanode/docker-compose.yml" <<EOF
services:
  remnawave-nginx:
    image: nginx:1.28
    restart: unless-stopped
    volumes:
      - $T/etc/letsencrypt/live/n.example.com/fullchain.pem:/etc/nginx/ssl/n.example.com/fullchain.pem:ro
  remnanode:
    image: remnawave/node:2.8.0
    restart: on-failure
    volumes:
      - $T/etc/letsencrypt:/etc/letsencrypt:ro
      - /dev/shm:/dev/shm:rw
EOF
printf 'server {\n    server_name n.example.com;\n    server_tokens off;\n}\n' > "$T/opt/remnanode/nginx.conf"
printf '<title>Kestrel</title>' > "$T/var/www/html/index.html"
: > "$T/etc/letsencrypt/live/n.example.com/fullchain.pem"

# --- заглушки ---------------------------------------------------------------
# docker помнит политику рестарта в файле, чтобы было видно, дошёл ли update.
printf 'no\n' > "$T/policy.remnanode"
printf 'no\n' > "$T/policy.remnawave-nginx"
cat > "$T/bin/docker" <<EOF
#!/usr/bin/env bash
T="$T"
case "\${1:-}" in
  inspect)
    for a in "\$@"; do case "\$a" in
      *RestartPolicy*) cat "\$T/policy.\${!#}" 2>/dev/null || echo no; exit 0 ;;
      *State.Status*)  echo running; exit 0 ;;
    esac; done
    echo running ;;
  update)
    for a in "\$@"; do case "\$a" in --restart=*) pol="\${a#--restart=}" ;; esac; done
    printf '%s\n' "\$pol" > "\$T/policy.\${!#}"; echo "\${!#} update" >> "\$T/docker.log" ;;
  compose) echo "compose \$*" >> "\$T/docker.log" ;;
  logs)    echo "[init-env] Xray version: Xray 26.6.27 (Xray) x (go1.26 linux/amd64)" ;;
  *) : ;;
esac
exit 0
EOF

# systemctl: помнит, что включили, и умеет отвечать на is-enabled.
: > "$T/enabled"
cat > "$T/bin/systemctl" <<EOF
#!/usr/bin/env bash
T="$T"
echo "systemctl \$*" >> "\$T/systemctl.log"
case "\${1:-}" in
  enable)
    for a in "\$@"; do case "\$a" in enable|--now) ;; *) echo "\$a" >> "\$T/enabled" ;; esac; done ;;
  is-enabled)
    grep -qx "\${2:-}" "\$T/enabled" && exit 0 || exit 1 ;;
esac
exit 0
EOF
cat > "$T/bin/df" <<'EOF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/vda1 40000000 8000000 32000000 20%% /\n'
EOF
chmod +x "$T/bin/"*

S="$T/run.sh"
sed -e "s|^DIR=\"/opt/remnanode\"|DIR=\"$T/opt/remnanode\"|" \
    -e "s|^AUTOSTART_UNIT=/etc/systemd|AUTOSTART_UNIT=$T/etc/systemd|" \
    -e "s|^AUTOSTART_TIMER=/etc/systemd|AUTOSTART_TIMER=$T/etc/systemd|" \
    -e "s|/etc/letsencrypt|$T/etc/letsencrypt|g" \
    -e "s|/var/www/html|$T/var/www/html|g" \
    -e "s|\"/root/|\"$T/root/|g" \
    -e 's|^\[ "$(id -u)" = "0" \] .*|:|' \
    node-setup.sh > "$S"

fail=0
ok()   { echo "  ✓ $1"; }
bad()  { echo "  ⚠ $1"; fail=1; }

echo "=== функции объявлены на верхнем уровне ==="
# Повод: cmd_cert_export однажды оказалась вложенной в install_node - файл
# парсился, а на живой ноде диспетчер получал "command not found".
for f in cmd_up ensure_autostart; do
  grep -qE "^$f\(\) \{" "$S" && ok "$f" || bad "$f не на верхнем уровне"
done

echo
echo "=== rr up ==="
OUT=$(bash "$S" up 2>&1); RC=$?
echo "$OUT" | sed 's/^/  /'
[ "$RC" = "0" ] || bad "up вернул $RC"

grep -q "compose up -d" "$T/docker.log" 2>/dev/null && ok "запустил docker compose up -d" \
  || bad "не позвал docker compose up -d"
grep -q -- "--force-recreate" "$T/docker.log" 2>/dev/null \
  && bad "up пересоздаёт контейнеры - должен просто поднимать" || ok "контейнеры не пересоздаются"
grep -q "compose pull" "$T/docker.log" 2>/dev/null \
  && bad "up делает pull - плавающий тег подменит ядро" || ok "pull не делается"

echo
echo "=== 1. демон включён в автозагрузку ==="
grep -qx "docker" "$T/enabled" && ok "systemctl enable docker" || bad "docker не включён в автозагрузку"

echo
echo "=== 2. слабая политика в compose поднята до always ==="
grep -qE 'restart:[[:space:]]*(unless-stopped|on-failure|no)$' "$T/opt/remnanode/docker-compose.yml" \
  && bad "в compose осталась слабая политика" || ok "слабых политик в compose не осталось"
[ "$(grep -c 'restart: always' "$T/opt/remnanode/docker-compose.yml")" = "2" ] \
  && ok "обе службы получили restart: always" || bad "restart: always не у обеих служб"
grep -q "$T/etc/letsencrypt" "$T/opt/remnanode/docker-compose.yml" \
  && ok "остальной compose не пострадал" || bad "sed испортил файл"

echo
echo "=== 3. политика применена к уже созданным контейнерам ==="
for c in remnanode remnawave-nginx; do
  [ "$(cat "$T/policy.$c")" = "always" ] && ok "$c: always" || bad "$c: политика не обновлена"
done

echo
echo "=== 4. сторож установлен ==="
U="$T/etc/systemd/system/remnanode-up.service"
V="$T/etc/systemd/system/remnanode-up.timer"
[ -s "$U" ] && ok "unit записан" || bad "unit не записан"
[ -s "$V" ] && ok "timer записан" || bad "timer не записан"
grep -q "WorkingDirectory=$T/opt/remnanode" "$U" 2>/dev/null && ok "unit смотрит в каталог ноды" \
  || bad "unit смотрит не туда"
grep -q "OnUnitActiveSec=" "$V" 2>/dev/null && ok "таймер периодический" || bad "таймер без периода"
# RemainAfterExit=yes оставил бы oneshot в состоянии active, и таймер больше
# никогда бы его не запустил - молча, один раз при загрузке.
grep -q "RemainAfterExit" "$U" 2>/dev/null \
  && bad "RemainAfterExit заблокирует повторные срабатывания" || ok "без RemainAfterExit"
grep -qx "remnanode-up.timer" "$T/enabled" && ok "таймер включён" || bad "таймер не включён"

echo
echo "=== check видит проблему, когда её ещё не починили ==="
# Откатываем всё в исходное состояние и смотрим, ругается ли health check.
printf 'no\n' > "$T/policy.remnanode"; printf 'no\n' > "$T/policy.remnawave-nginx"
: > "$T/enabled"
OUT=$(bash "$S" check 2>&1)
echo "$OUT" | grep -q "NOT enabled at boot" && ok "check ловит выключенный демон" \
  || bad "check не заметил, что docker не в автозагрузке"
echo "$OUT" | grep -q "expected always" && ok "check ловит слабую политику" \
  || bad "check не заметил политику рестарта"
echo "$OUT" | grep -q "watchdog timer: not installed" && ok "check ловит отсутствие сторожа" \
  || bad "check не заметил отсутствие таймера"
echo "$OUT" | grep -q "hardened nginx config written" && bad "check провалился в setup"

echo
[ "$fail" = "0" ] && echo "ВСЕ ПРОВЕРКИ ПРОШЛИ" || echo "ЕСТЬ ПРОБЛЕМЫ"
rm -rf "$T"
exit $fail
