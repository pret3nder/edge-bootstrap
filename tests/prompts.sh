#!/usr/bin/env bash
# Регулярки, которые ask() передаёт в grep -E.
#
# Повод: токен GCore проверялся шаблоном '.\{8,\}'. Это синтаксис БАЗОВЫХ
# регулярок; в ERE '\{' — литеральная фигурная скобка, поэтому шаблон не
# совпадал НИ С ЧЕМ. Ошибка выглядела как "неверный токен", хотя токен был
# рабочий, и повторный ввод не помогал никогда.
set -u
fail=0
S=node-setup.sh

echo "=== ни одной BRE-скобки в шаблонах для grep -E ==="
bad=$(grep -nE "ask \"[^\"]*\" [A-Za-z_]+ '[^']*\\\\[{}]" "$S" || true)
if [ -n "$bad" ]; then
  echo "  ⚠ найден BRE-синтаксис в ERE-шаблоне:"; printf '%s\n' "$bad" | sed 's/^/    /'; fail=1
else
  echo "  ✓ нет"
fi

echo
echo "=== каждый шаблон принимает то, что должен ==="
# шаблон | значение | ожидание(ok|no)
while IFS='|' read -r re val want; do
  [ -n "$re" ] || continue
  got=no
  printf '%s' "$val" | grep -qE "$re" 2>/dev/null && got=ok
  if [ "$got" = "$want" ]; then
    printf '  ✓ %-28s %s\n' "$(printf '%.28s' "$val")" "$want"
  else
    printf '  ⚠ %-28s ждали %s, вышло %s   (%s)\n' "$(printf '%.28s' "$val")" "$want" "$got" "$re"; fail=1
  fi
done <<'CASES'
^[^[:space:]]{16,}$|35175_0a228c7de05327175fc623b1f81f1027796f2f6444e4ecfd0061001f|ok
^[^[:space:]]{16,}$|short|no
^[^[:space:]]{16,}$|token with spaces inside|no
^[12]$|1|ok
^[12]$|2|ok
^[12]$|3|no
^[12]$||no
^[A-Za-z0-9+/=_-]{80,}$|eyJub2RlQ2VydFBlbSI6IkZBS0VLRVlGT1JURVNUSU5HMTIzNDU2Nzg5MEFCQ0RFRkdISUpLTE1OT1BRUlNU|ok
^[A-Za-z0-9+/=_-]{80,}$|tooshort|no
^([0-9]{1,3}\.){3}[0-9]{1,3}$|144.31.4.204|ok
^([0-9]{1,3}\.){3}[0-9]{1,3}$|nope|no
CASES

echo
echo "=== шаблоны из скрипта совпадают с проверенными здесь ==="
for pair in "RE_TOKEN|^\[\^\[:space:\]\]{16,}\$" ; do
  n="${pair%%|*}"
  grep -qE "^$n='" "$S" && echo "  ✓ $n определён в скрипте" || { echo "  ⚠ $n пропал из скрипта"; fail=1; }
done
grep -q "GCORE_TOKEN \"\$RE_TOKEN\"" "$S" && echo "  ✓ оба запроса токена используют RE_TOKEN" \
  || { echo "  ⚠ запрос токена не использует RE_TOKEN"; fail=1; }
c=$(grep -c 'GCORE_TOKEN "\$RE_TOKEN"' "$S" || true)
[ "$c" = "2" ] && echo "  ✓ найдено 2 запроса токена" || { echo "  ⚠ ожидали 2 запроса токена, нашли $c"; fail=1; }

echo
[ "$fail" = "0" ] && echo "ВСЕ ПРОВЕРКИ ПРОШЛИ" || echo "ЕСТЬ ПРОБЛЕМЫ"
exit $fail
