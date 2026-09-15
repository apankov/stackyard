#!/usr/bin/env bash
#
# На какой версии stackyard работает каждая машина парка.
#
# Существует ради одного вопроса, на который иначе нет быстрого ответа: доехал
# ли фикс до всех. Когда платформа лежала в машинах копиями, это означало
# сравнение содержимого десятков файлов по каждому репозиторию; со
# закреплением по коммиту — одна строка на машину.
#
#   ./bin/fleet.sh ~/dev/machines/*        # по путям
#   ./bin/fleet.sh                         # из ~/.stackyard-fleet, по строке на путь

set -uo pipefail

ROOT="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
HEAD_COMMIT="$( cd "$ROOT" && git rev-parse HEAD )"
HEAD_VERSION="v$(cat "$ROOT/platform/VERSION")"

paths=("$@")
if [ ${#paths[@]} -eq 0 ]; then
  list="${HOME}/.stackyard-fleet"
  [ -f "$list" ] || { echo "Укажите пути к машинам или заведите $list" >&2; exit 2; }
  mapfile -t paths < <(grep -vE '^\s*(#|$)' "$list")
fi

printf '%-24s %-10s %-10s %s\n' МАШИНА ВЕРСИЯ ОТСТАЁТ КОММИТ
behind=0
for p in "${paths[@]}"; do
  [ -d "$p" ] || continue
  lock="$p/stackyard.lock"
  name="$(basename "$p")"
  if [ ! -f "$lock" ]; then
    printf '%-24s %-10s %-10s %s\n' "$name" "—" "—" "не машина stackyard"
    continue
  fi
  v="$(grep -E '^version=' "$lock" | cut -d= -f2-)"
  c="$(grep -E '^commit='  "$lock" | cut -d= -f2-)"
  if [ "$c" = "$HEAD_COMMIT" ]; then
    lag="нет"
  else
    # Считаем именно коммиты, ЗАТРАГИВАЮЩИЕ платформу: машина, отставшая на
    # двадцать коммитов в README, не отстала ни на что.
    n="$( cd "$ROOT" && git rev-list --count "$c..$HEAD_COMMIT" -- platform profiles 2>/dev/null || echo '?' )"
    lag="$n"
    [ "$n" != "0" ] && behind=$((behind + 1))
  fi
  printf '%-24s %-10s %-10s %s\n' "$name" "$v" "$lag" "${c:0:12}"
done

echo
echo "В stackyard: $HEAD_VERSION (${HEAD_COMMIT:0:12})"
[ "$behind" -gt 0 ] && echo "Отстают по платформе: $behind. Обновить: ./bin/pin.sh <машина>"
exit 0
