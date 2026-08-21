#!/usr/bin/env bash
# Проверка drop_rules против заглушки ufw, которая перенумеровывает правила
# после удаления — как это делает настоящий ufw.
set -euo pipefail
T=$(mktemp -d); export PATH="$T/bin:$PATH"; mkdir -p "$T/bin"
export UFW_STATE="$T/ufw.txt"

cat > "$T/bin/ufw" <<'STUB'
#!/usr/bin/env bash
renumber() {
  awk 'BEGIN{c=0}
       /^\[/ { c++; sub(/^\[[ 0-9]*\]/, sprintf("[%2d]", c)) }
       { print }' "$1" > "$1.t" && mv "$1.t" "$1"
}
case "${1:-}" in
  status) cat "$UFW_STATE" ;;
  --force)
    n="$3"
    awk -v n="$n" 'BEGIN{c=0} /^\[/{c++; if(c==n) next} {print}' "$UFW_STATE" > "$UFW_STATE.t"
    mv "$UFW_STATE.t" "$UFW_STATE"
    renumber "$UFW_STATE" ;;
  allow|reload) : ;;
esac
exit 0
STUB
chmod +x "$T/bin/ufw"

cat > "$UFW_STATE" <<'EOF'
Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 22/tcp                     ALLOW IN    Anywhere
[ 2] 443/tcp                    ALLOW IN    Anywhere
[ 3] 2053/tcp                   ALLOW IN    Anywhere
[ 4] 8443/tcp                   ALLOW IN    Anywhere
[ 5] 443,2222/tcp               ALLOW IN    Anywhere
[ 6] 2222/tcp                   ALLOW IN    144.31.4.204
[ 7] 2053/tcp (v6)              ALLOW IN    Anywhere (v6)
[ 8] 8443/tcp (v6)              ALLOW IN    Anywhere (v6)
EOF

echo "=== было ==="; grep '^\[' "$UFW_STATE" | sed 's/^/  /'

# --- ровно та функция, что в node-setup.sh ---
drop_rules() {
  local re="$1" n guard=0
  while [ $guard -lt 40 ]; do
    n=$(ufw status numbered 2>/dev/null | grep -E "$re" | head -1 | sed -E 's/^\[[[:space:]]*([0-9]+)\].*/\1/' || true)
    [ -n "$n" ] || return 0
    ufw --force delete "$n" >/dev/null 2>&1 || return 0
    guard=$((guard + 1))
  done
}

for p in 2053 8443; do
  drop_rules "^\[[ 0-9]+\].*(^|[^0-9])$p([^0-9]|\$)" && true
done
drop_rules "^\[[ 0-9]+\].*2222.*(Anywhere|0\.0\.0\.0)"

echo; echo "=== стало ==="; grep '^\[' "$UFW_STATE" | sed 's/^/  /'
echo
fail=0
for bad in 2053 8443; do
  if grep -qE "(^|[^0-9])$bad([^0-9]|$)" "$UFW_STATE"; then echo "  ⚠ $bad ВЫЖИЛ"; fail=1; else echo "  ✓ $bad закрыт"; fi
done
grep -qE '2222.*Anywhere' "$UFW_STATE" && { echo "  ⚠ широкое 2222 выжило"; fail=1; } || echo "  ✓ широкое 2222 удалено"
grep -qE '^\[.*22/tcp' "$UFW_STATE"        && echo "  ✓ SSH цел"                 || { echo "  ⚠ SSH УДАЛЁН"; fail=1; }
grep -qE '2222.*144\.31\.4\.204' "$UFW_STATE" && echo "  ✓ ограниченное 2222 цело" || { echo "  ⚠ ограниченное 2222 удалено"; fail=1; }
rm -rf "$T"
exit $fail
