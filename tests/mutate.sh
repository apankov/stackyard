#!/usr/bin/env bash
#
# Мутационный прогон selftest: ломаем движок по одной функции и смотрим, падает
# ли тест.
#
# Существует потому, что зелёный selftest сам по себе ничего не доказывает.
# Прогон, сделанный однажды руками, нашёл 11 непойманных поломок из 18 — в том
# числе весь механизм двух корней. Проверка, которая не падает на сломанном
# коде, хуже отсутствия проверки: она служит разрешением не думать.
#
#   ./tests/mutate.sh          все мутации
#   ./tests/mutate.sh два      только те, чьё имя содержит подстроку
#
# Работает на КЛОНЕ в /tmp: рабочее дерево не трогается вовсе.

set -uo pipefail

ROOT="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
FILTER="${1:-}"

# Мутация: имя @@ файл @@ что заменить @@ на что.
#
# Разделитель @@, а не |: вертикальная черта встречается в самих образцах
# (regexp вида (proxy_pass|fastcgi_pass)), и мутация молча не применялась —
# то есть прогон докладывал о проверке, которой не было.
#
# Каждая обязана быть ПРАВДОПОДОБНОЙ — такой, какую можно сделать по
# невнимательности. Мутация, которую никто не напишет, ничего не проверяет.
MUTATIONS=(
  'два корня: профильный выключен@@platform/lib/lib-stacks.sh@@  [ -d "$(stacks_root)/profile/stacks" ] \&\& printf@@  false \&\& printf'
  'два корня: перечисление только машинного@@platform/lib/lib-stacks.sh@@done < <(stack_roots) | sort -u@@done < <(printf "%s/stacks\\n" "$(stacks_root)") | sort -u'
  'stack_dir: приоритет корней обратный@@platform/lib/lib-stacks.sh@@  while IFS= read -r r; do\n    [ -f "$r/$1/stack.conf" ]@@  while IFS= read -r r; do\n    [ -f "$r/$1/stack.conf" ] \&\& [ "$r" != "$(stacks_root)/stacks" ]'
  'include: профиль указывает в машинный путь@@platform/lib/lib-stacks.sh@@    "$(stacks_root)/profile/stacks/"*) printf@@    "$(stacks_root)/NEVER/"*) printf'
  'stack_env_file: .env ищется в профиле@@platform/lib/lib-stacks.sh@@printf '"'"'%s/stacks/%s/.env'"'"'@@printf '"'"'%s/profile/stacks/%s/.env'"'"''
  'домены: алиасы теряются@@platform/lib/lib-stacks.sh@@[ "$1" = "${1#*+}" ] ||@@true ||'
  'заказ базы: префикс зашит@@platform/lib/lib-stacks.sh@@  [ -n "$p" ] \&\& stack_conf_get "$p" Provides_DB@@  [ -n "$p" ] \&\& printf Postgres'
  'бэкап: формула пути sqlite изменена@@platform/lib/lib-env.sh@@printf '"'"'sqlite/%s'"'"'@@printf '"'"'sqlitebackup/%s'"'"''
  'upstream: fastcgi_pass не учитывается@@platform/lib/lib-stacks.sh@@(proxy_pass|fastcgi_pass)@@(proxy_pass)'
  'stack_services: платформенные не исключаются@@platform/lib/lib-stacks.sh@@  base_services=$(platform_services)@@  base_services=""'
  'missing_files: compose не обязателен@@platform/lib/lib-stacks.sh@@  if [ "$(stack_conf_get "$s" Containers yes)" != "no" ] \&\&@@  if false \&\&'
  'missing_files: образец ищется по машинному пути@@platform/lib/lib-stacks.sh@@  if [ -f "$(stack_dir "$s")/.env.example" ]@@  if [ -f "$(stacks_root)/stacks/$s/.env.example" ]'
  'юниты: @STACK_DIR@ теряет корень@@platform/lib/lib-stacks.sh@@${DEPLOY_DIR:?}$(_stack_dir_suffix "$stack")@@${DEPLOY_DIR:?}/stacks/$stack'
  'бэкап: gzip опознаётся как SQLite (A2)@@platform/lib/lib-env.sh@@    1f8b*) ;;                                                          # gzip — смотрим внутрь@@    1f8b*) printf sqlite_gz; return 0 ;;'
  'бэкап: tar под gzip не отличается@@platform/lib/lib-env.sh@@    7573746172*) printf '"'"'tar_gz'"'"'; return 0 ;;@@    7573746172*) printf unknown; return 0 ;;'
  'seed: инициализатор читает другой ключ (A3)@@profiles/stacks/mysql/db-init/initializer.sh@@yq e '"'"'.dump // ""'"'"' -@@yq e '"'"'.dump_file // ""'"'"' -'
  'статика: собирается по включённым@@platform/lib/lib-stacks.sh@@  done < <(stacks_available)\n\n  cat <<@@  done < <(stacks_enabled)\n\n  cat <<'
)

pass=0; miss=0
printf '%-52s %s\n' МУТАЦИЯ РЕЗУЛЬТАТ
for m in "${MUTATIONS[@]}"; do
  IFS=$'\034' read -r name file old new <<< "${m//@@/$'\034'}"
  case "$name" in *"$FILTER"*) ;; *) continue ;; esac

  W=$(mktemp -d); cp -R "$ROOT"/. "$W"/ 2>/dev/null
  rm -rf "$W/.git"

  # Замену делает python: sed по многострочным образцам с кавычками ненадёжен,
  # а неприменившаяся мутация — это тест, который «поймал» несуществующую
  # поломку. Поэтому применение проверяется, и неприменившаяся считается
  # ошибкой прогона, а не успехом.
  applied=$(W="$W" F="$file" O="$old" N="$new" python3 - <<'PY'
import io, os
p = os.path.join(os.environ['W'], os.environ['F'])
s = io.open(p, encoding='utf-8').read()
old = os.environ['O'].replace('\\n', '\n').replace('\\&', '&')
new = os.environ['N'].replace('\\n', '\n').replace('\\&', '&')
if old in s:
    io.open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1)); print('yes')
else:
    print('no')
PY
)
  if [ "$applied" != yes ]; then
    printf '%-52s \033[33mНЕ ПРИМЕНИЛАСЬ\033[0m (образец устарел)\n' "$name"
    rm -rf "$W"; miss=$((miss + 1)); continue
  fi

  if ( cd "$W" && ./platform/bin/selftest.sh ) >/dev/null 2>&1; then
    printf '%-52s \033[31mНЕ ПОЙМАНА\033[0m\n' "$name"; miss=$((miss + 1))
  else
    printf '%-52s пойман\n' "$name"; pass=$((pass + 1))
  fi
  rm -rf "$W"
done

echo
echo "поймано: $pass, пропущено: $miss"
[ "$miss" -eq 0 ]
