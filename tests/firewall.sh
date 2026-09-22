#!/usr/bin/env bash
# rr firewall против заглушек: ufw с состоянием и перенумерацией (как настоящий),
# ss с владельцами сокетов, systemctl. Запускается настоящий node-setup.sh.
set -u
T=$(mktemp -d); export PATH="$T/bin:$PATH"
mkdir -p "$T/bin" "$T/opt/remnanode" "$T/systemd" "$T/state"
export UFW_STATE="$T/ufw.txt" SS_OUT="$T/ss.txt" SYSD="$T/systemd"
printf 'services:\n  remnanode:\n    image: remnawave/node:2.8.0\n' > "$T/opt/remnanode/docker-compose.yml"

cat > "$T/bin/ufw" <<'STUB'
#!/usr/bin/env bash
renumber() {
  awk 'BEGIN{c=0} /^\[/ { c++; sub(/^\[[ 0-9]*\]/, sprintf("[%2d]", c)) } { print }' "$UFW_STATE" > "$UFW_STATE.t" && mv "$UFW_STATE.t" "$UFW_STATE"
}
add() { printf '[99] %-26s ALLOW IN    %s\n' "$1" "$2" >> "$UFW_STATE"; renumber; }
case "${1:-}" in
  status) cat "$UFW_STATE" ;;
  --force)
    [ "${2:-}" = enable ] && exit 0
    awk -v n="$3" 'BEGIN{c=0} /^\[/{c++; if(c==n) next} {print}' "$UFW_STATE" > "$UFW_STATE.t"
    mv "$UFW_STATE.t" "$UFW_STATE"; renumber ;;
  allow)
    if [ "${2:-}" = from ]; then add "$7/$9" "$3"   # allow from IP to any port P proto tcp
    else spec="$2"; add "$spec" "Anywhere"; add "$spec (v6)" "Anywhere (v6)"; fi ;;
  reload) : ;;
esac
exit 0
STUB
cat > "$T/bin/ss" <<'STUB'
#!/usr/bin/env bash
cat "$SS_OUT"
STUB
cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in is-enabled) [ -f "$SYSD/enabled" ] ;; enable) : > "$SYSD/enabled" ;; *) : ;; esac
STUB
chmod +x "$T/bin/"*

S="$T/run.sh"
sed -e "s|^DIR=\"/opt/remnanode\"|DIR=\"$T/opt/remnanode\"|" \
    -e "s|^FW_STATE_DIR=/var/lib/rr|FW_STATE_DIR=$T/state|" \
    -e "s|/etc/systemd/system/|$T/systemd/|g" \
    -e 's|^\[ "$(id -u)" = "0" \] .*|:|' \
    node-setup.sh > "$S"

fail=0
rules() { grep '^\[' "$UFW_STATE" | sed -E 's/^\[[ 0-9]+\] +//; s/ +ALLOW IN +/ <- /; s/ +# .*//; s/ +$//'; }
has()   { rules | grep -qxF "$1"; }
want()  { has "$1" && echo "  ✓ есть:  $1" || { echo "  ⚠ НЕТ:   $1"; fail=1; }; }
gone()  { has "$1" && { echo "  ⚠ ОСТАЛОСЬ: $1"; fail=1; } || echo "  ✓ нет:   $1"; }

live_ss() {
  cat > "$SS_OUT" <<'EOF'
tcp LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("xray",pid=10,fd=7))
udp UNCONN 0 0 *:443 *:* users:(("xray",pid=10,fd=9))
tcp LISTEN 0 4096 [::]:2083 [::]:* users:(("xray",pid=10,fd=8))
tcp LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=20,fd=6),("nginx",pid=21,fd=6))
tcp LISTEN 0 511 127.0.0.1:8081 0.0.0.0:* users:(("nginx",pid=20,fd=7))
tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=30,fd=3),("systemd",pid=1,fd=40))
tcp LISTEN 0 4096 *:2222 *:* users:(("node",pid=40,fd=20))
udp UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=50,fd=14))
EOF
}
fresh_rules() {
  cat > "$UFW_STATE" <<'EOF'
Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 22/tcp                     ALLOW IN    Anywhere                   # SSH
[ 2] 443/tcp                    ALLOW IN    Anywhere
[ 3] 443/udp                    ALLOW IN    Anywhere
[ 4] 80/tcp                     ALLOW IN    Anywhere
[ 5] 8443/tcp                   ALLOW IN    Anywhere                   # Trojan
[ 6] 2053/tcp                   ALLOW IN    Anywhere
[ 7] 443,2222/tcp               ALLOW IN    Anywhere
[ 8] 2222/tcp                   ALLOW IN    192.0.2.10
[ 9] 2222/tcp                   ALLOW IN    203.0.113.9
[10] 3000/tcp                   ALLOW IN    198.51.100.7
[11] OpenSSH                    ALLOW IN    Anywhere
[12] 22,9443/tcp                ALLOW IN    Anywhere
[13] 8443/tcp (v6)              ALLOW IN    Anywhere (v6)
[14] 2053/tcp (v6)              ALLOW IN    Anywhere (v6)
EOF
}

echo "=== 1. живая нода: открыть 2083, закрыть 8443/2053/мультипорт с 2222, чужой 2222 ==="
live_ss; fresh_rules
OUT=$(bash "$S" firewall 2>&1); RC=$?
echo "$OUT" | sed 's/^/  | /'
[ "$RC" = 0 ] || { echo "  ⚠ код $RC"; fail=1; }
want "22/tcp <- Anywhere"; want "443/tcp <- Anywhere"; want "443/udp <- Anywhere"; want "80/tcp <- Anywhere"
want "2083/tcp <- Anywhere"; want "2083/tcp (v6) <- Anywhere (v6)"
want "2222/tcp <- 192.0.2.10"; want "3000/tcp <- 198.51.100.7"; want "OpenSSH <- Anywhere"
want "22,9443/tcp <- Anywhere"   # правило с SSH не трогается никогда
gone "8443/tcp <- Anywhere"; gone "8443/tcp (v6) <- Anywhere (v6)"
gone "2053/tcp <- Anywhere"; gone "2053/tcp (v6) <- Anywhere (v6)"
gone "443,2222/tcp <- Anywhere"; gone "2222/tcp <- 203.0.113.9"
gone "8081/tcp <- Anywhere"      # loopback-сокет nginx не публикуется
[ -f "$T/systemd/remnanode-fw.timer" ] && echo "  ✓ таймер записан" || { echo "  ⚠ таймера нет"; fail=1; }
grep -q 'rr firewall --auto' "$T/systemd/remnanode-fw.service" && echo "  ✓ таймер зовёт --auto" || { echo "  ⚠ unit не тот"; fail=1; }

echo; echo "=== 2. повторный прогон ничего не меняет ==="
cp "$UFW_STATE" "$T/before"
bash "$S" firewall >/dev/null 2>&1
diff -q "$T/before" "$UFW_STATE" >/dev/null && echo "  ✓ идемпотентно" || { echo "  ⚠ второй прогон изменил правила"; diff "$T/before" "$UFW_STATE" | sed 's/^/    /'; fail=1; }

echo; echo "=== 3. --dry-run не меняет ничего и показывает план ==="
fresh_rules; cp "$UFW_STATE" "$T/before"; rm -f "$T/state/fw-unused"
OUT=$(bash "$S" firewall --dry-run 2>&1); RC=$?
diff -q "$T/before" "$UFW_STATE" >/dev/null && echo "  ✓ правила не тронуты" || { echo "  ⚠ dry-run изменил правила"; fail=1; }
[ ! -e "$T/state/fw-unused" ] && echo "  ✓ состояние не записано" || { echo "  ⚠ dry-run записал состояние"; fail=1; }
echo "$OUT" | grep -q "would open 2083/tcp" && echo "  ✓ план: открыть 2083" || { echo "  ⚠ нет 'would open 2083/tcp'"; fail=1; }
echo "$OUT" | grep -q "would close 8443/tcp" && echo "  ✓ план: закрыть 8443" || { echo "  ⚠ нет 'would close 8443/tcp'"; fail=1; }
echo "$OUT" | grep -qi "domain" && { echo "  ⚠ --dry-run принят за домен"; fail=1; } || echo "  ✓ --dry-run не принят за домен"
[ "$RC" = 0 ] || { echo "  ⚠ код $RC"; fail=1; }

echo; echo "=== 4. --auto закрывает только со второго раза (рестарт ядра не роняет порт) ==="
fresh_rules; rm -f "$T/state/fw-unused"
bash "$S" firewall --auto >/dev/null 2>&1
has "8443/tcp <- Anywhere" && echo "  ✓ первый --auto: 8443 ещё открыт" || { echo "  ⚠ первый --auto уже закрыл"; fail=1; }
has "2083/tcp <- Anywhere" && echo "  ✓ первый --auto: 2083 открыт сразу" || { echo "  ⚠ 2083 не открыт"; fail=1; }
bash "$S" firewall --auto >/dev/null 2>&1
has "8443/tcp <- Anywhere" && { echo "  ⚠ второй --auto не закрыл 8443"; fail=1; } || echo "  ✓ второй --auto: 8443 закрыт"
[ -e "$T/systemd/enabled" ] && [ "$(ls "$T/systemd")" ] ; :

echo; echo "=== 5. xray не слушает (рестарт / профиль не пришёл): ничего не закрывать ==="
grep -v '"xray"' "$SS_OUT" > "$SS_OUT.t"; mv "$SS_OUT.t" "$SS_OUT"
fresh_rules; cp "$UFW_STATE" "$T/before"
OUT=$(bash "$S" firewall 2>&1)
has "8443/tcp <- Anywhere" && echo "  ✓ 8443 не тронут" || { echo "  ⚠ закрыл без ядра"; fail=1; }
echo "$OUT" | grep -q "closing skipped" && echo "  ✓ сказал, почему" || { echo "  ⚠ нет объяснения"; fail=1; }

echo; echo "=== 5b. свежая установка: ничего не слушает, пустой ufw -> базовая схема открыта ==="
printf 'tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=30,fd=3))\n' > "$SS_OUT"
printf 'Status: active\n\n     To  Action  From\n     --  ------  ----\n' > "$UFW_STATE"
bash "$S" firewall --panel-ip 192.0.2.10 >/dev/null 2>&1
want "80/tcp <- Anywhere"; want "443/tcp <- Anywhere"; want "443/udp <- Anywhere"; want "22/tcp <- Anywhere"
want "2222/tcp <- 192.0.2.10"; gone "2222/tcp <- Anywhere"

echo; echo "=== 6. порт за nginx (CDN-нода): xray на 0.0.0.0:4443 не публикуется ==="
live_ss; echo 'tcp LISTEN 0 4096 0.0.0.0:4443 0.0.0.0:* users:(("xray",pid=10,fd=11))' >> "$SS_OUT"
printf 'server {\n  location / { proxy_pass http://127.0.0.1:4443; }\n}\n' > "$T/opt/remnanode/nginx.conf"
fresh_rules; printf '[15] 4443/tcp                   ALLOW IN    Anywhere\n' >> "$UFW_STATE"
bash "$S" firewall >/dev/null 2>&1
gone "4443/tcp <- Anywhere"
rm -f "$T/opt/remnanode/nginx.conf"

echo; echo "=== 7. check показывает расхождение и ничего не меняет ==="
live_ss; fresh_rules; cp "$UFW_STATE" "$T/before"
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in inspect) echo running ;; logs) echo "Xray version: Xray 26.6.27" ;; esac
exit 0
EOF
chmod +x "$T/bin/docker"
OUT=$(bash "$S" check 2>&1)
diff -q "$T/before" "$UFW_STATE" >/dev/null && echo "  ✓ check не менял правила" || { echo "  ⚠ check изменил правила"; fail=1; }
echo "$OUT" | grep -q "served port is closed" && echo "  ✓ check видит закрытый 2083" || { echo "  ⚠ check не заметил 2083"; fail=1; }

echo
[ "$fail" = 0 ] && echo "ВСЕ ПРОВЕРКИ ПРОШЛИ" || echo "ЕСТЬ ПРОБЛЕМЫ"
rm -rf "$T"
exit $fail
