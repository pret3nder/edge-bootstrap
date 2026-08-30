#!/usr/bin/env bash
# На перенятой ноде `rr` оказался алиасом чужого установщика на команду
# remnawave_reverse, которой на хосте давно нет. Алиас сильнее PATH, поэтому
# наш /usr/local/bin/rr не запускался вообще, а `rr` отвечал "command not found"
# ровно на той ноде, где инструмент был нужнее всего.
# Проверяем: мёртвый алиас удаляется, живой не трогается, check о нём говорит
# и при этом ничего не меняет.
set -u
T=$(mktemp -d); export PATH="$T/bin:$PATH"; export HOME="$T/home"
mkdir -p "$T/bin" "$T/home" "$T/etc" "$T/opt/remnanode" "$T/etc/systemd/system" \
         "$T/var/www/html" "$T/root" "$T/etc/letsencrypt/live/n.example.com" "$T/run"

cat > "$T/opt/remnanode/docker-compose.yml" <<EOF
services:
  remnawave-nginx:
    image: nginx:1.28
    restart: always
    volumes:
      - $T/etc/letsencrypt/live/n.example.com/fullchain.pem:/etc/nginx/ssl/n.example.com/fullchain.pem:ro
  remnanode:
    image: remnawave/node:2.8.0
    restart: always
    volumes:
      - $T/etc/letsencrypt:/etc/letsencrypt:ro
EOF
printf 'server {\n    server_name n.example.com;\n    server_tokens off;\n}\n' > "$T/opt/remnanode/nginx.conf"
printf '<title>Kestrel</title>' > "$T/var/www/html/index.html"
: > "$T/etc/letsencrypt/live/n.example.com/fullchain.pem"

cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  inspect) for a in "$@"; do case "$a" in *RestartPolicy*) echo always; exit 0 ;; esac; done; echo running ;;
  logs)    echo "[init-env] Xray version: Xray 26.6.27 (Xray) x (go1.26 linux/amd64)" ;;
  *) : ;;
esac
exit 0
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "is-enabled" ] && exit 0
exit 0
EOF
cat > "$T/bin/df" <<'EOF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/vda1 40000000 8000000 32000000 20%% /\n'
EOF
# Живая команда, на которую будет указывать "хороший" алиас.
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/othertool"
chmod +x "$T/bin/"*

S="$T/run.sh"
build() {
  sed -e "s|^DIR=\"/opt/remnanode\"|DIR=\"$T/opt/remnanode\"|" \
      -e "s|^REBOOT_FLAG=.*|REBOOT_FLAG=$T/run/reboot-required|" \
      -e "s|^RC_FILES=.*|RC_FILES=\"$T/etc/bash.bashrc $T/root/.bashrc\"|" \
      -e "s|^AUTOSTART_UNIT=/etc/systemd|AUTOSTART_UNIT=$T/etc/systemd|" \
      -e "s|^AUTOSTART_TIMER=/etc/systemd|AUTOSTART_TIMER=$T/etc/systemd|" \
      -e "s|/etc/letsencrypt|$T/etc/letsencrypt|g" \
      -e "s|/var/www/html|$T/var/www/html|g" \
      -e "s|\"/root/|\"$T/root/|g" \
      -e 's|^\[ "$(id -u)" = "0" \] .*|:|' \
      node-setup.sh > "$S"
}
build

fail=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ⚠ $1"; fail=1; }

reset_rc() {
  printf '# system-wide bashrc\nexport EDITOR=nano\n%s\n' "$1" > "$T/etc/bash.bashrc"
  rm -f "$T"/etc/bash.bashrc.bak-* "$T/root/.bashrc"
}

echo "=== мёртвый алиас удаляется ==="
reset_rc "alias rr='remnawave_reverse'"
OUT=$(bash "$S" up 2>&1)
echo "$OUT" | grep -q "removed a dead 'rr' alias" && ok "сказал, что удалил" || bad "молча или не удалил"
grep -q "alias rr=" "$T/etc/bash.bashrc" && bad "алиас остался в файле" || ok "строки в файле нет"
grep -q "EDITOR=nano" "$T/etc/bash.bashrc" && ok "остальной файл цел" || bad "sed снёс лишнее"
ls "$T"/etc/bash.bashrc.bak-* >/dev/null 2>&1 && ok "бэкап файла создан" || bad "бэкапа нет"
echo "$OUT" | grep -q "unalias rr" && ok "подсказал про текущую сессию" || bad "не сказал про unalias"

echo
echo "=== живой алиас не трогается ==="
reset_rc "alias rr='othertool --flag'"
OUT=$(bash "$S" up 2>&1)
grep -q "alias rr=" "$T/etc/bash.bashrc" && ok "строка на месте" || bad "удалил живой алиас"
echo "$OUT" | grep -q "leaving it alone" && ok "предупредил и не тронул" || bad "нет предупреждения"

echo
echo "=== алиаса нет - ничего не делает ==="
reset_rc "# no alias here"
OUT=$(bash "$S" up 2>&1)
echo "$OUT" | grep -qi "alias" && bad "шумит про алиас, которого нет" || ok "молчит"
ls "$T"/etc/bash.bashrc.bak-* >/dev/null 2>&1 && bad "сделал лишний бэкап" || ok "лишних бэкапов нет"

echo
echo "=== check видит мёртвый алиас и остаётся read-only ==="
reset_rc "alias rr='remnawave_reverse'"
SUM_BEFORE=$(cksum "$T/etc/bash.bashrc")
OUT=$(bash "$S" check 2>&1)
echo "$OUT" | grep -q "shell alias:" && ok "check о нём говорит" || bad "check промолчал"
echo "$OUT" | grep -q "points at a command that is gone" && ok "check назвал причину" \
  || bad "check не отличил мёртвый алиас от живого"
[ "$(cksum "$T/etc/bash.bashrc")" = "$SUM_BEFORE" ] && ok "check файл не менял" \
  || bad "check ИЗМЕНИЛ rc-файл (должен быть read-only)"

echo
echo "=== check предупреждает про ожидающую перезагрузку ==="
# Именно этот случай и уронил ноду: висел *** System restart required ***,
# её перезагрузили, а docker не был в автозагрузке.
reset_rc "# no alias here"
: > "$T/run/reboot-required"
OUT=$(bash "$S" check 2>&1)
echo "$OUT" | grep -q "reboot pending" && ok "check видит флаг перезагрузки" || bad "check его не заметил"
rm -f "$T/run/reboot-required"
OUT=$(bash "$S" check 2>&1)
echo "$OUT" | grep -q "reboot pending" && bad "говорит про перезагрузку без флага" || ok "без флага молчит"

echo
echo "=== функции объявлены на верхнем уровне ==="
for f in fix_rr_alias alias_line alias_target; do
  grep -qE "^$f\(\) \{" "$S" && ok "$f" || bad "$f не на верхнем уровне"
done

echo
[ "$fail" = "0" ] && echo "ВСЕ ПРОВЕРКИ ПРОШЛИ" || echo "ЕСТЬ ПРОБЛЕМЫ"
rm -rf "$T"
exit $fail
