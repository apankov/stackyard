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
  'бэкап: gzip опознаётся как SQLite (A2)@@platform/lib/lib-env.sh@@    1f8b*) ;;                                                          # gzip — look inside@@    1f8b*) printf sqlite_gz; return 0 ;;'
  'бэкап: tar под gzip не отличается@@platform/lib/lib-env.sh@@    7573746172*) printf '"'"'tar_gz'"'"'; return 0 ;;@@    7573746172*) printf unknown; return 0 ;;'
  'seed: инициализатор читает другой ключ (A3)@@profiles/stacks/mysql/db-init/initializer.sh@@yq e '"'"'.dump // ""'"'"' -@@yq e '"'"'.dump_file // ""'"'"' -'
  'свежая машина: state/ не заводится (B1)@@platform/lib/lib-stacks.sh@@  mkdir -p "$root/state/nginx-vhosts"@@  mkdir -p "$root/state/NOPE"  #'
  'свежая машина: каталог поставщика не заводится (A5)@@platform/lib/lib-stacks.sh@@  [ -n "$p" ] \&\& mkdir -p "$root/state/$p"@@  [ -n "$p" ] \&\& true'
  'заглушки: профильный стек не сканируется (A4)@@platform/lib/lib-stacks.sh@@  done < <(stacks_available)\n  grep -rhE@@  done < <(stacks_enabled 2>/dev/null | grep -v .)\n  grep -rhE'
  'include: читатель ищет не ту строку (A6)@@platform/lib/lib-stacks.sh@@  want="include $(stack_dir_in_container "$1")/nginx/*.conf;"@@  want="conf.d/$1/*.conf"'
  'health: библиотека по пути devbox6 (A9)@@profiles/stacks/mysql/scripts/health.sh@@. "$ROOT_DIR/platform/lib/lib-env.sh"@@. "$ROOT_DIR/scripts/lib-env.sh"'
  'include: файл снова сортируется раньше зон (A15)@@platform/lib/lib-stacks.sh@@state/nginx-vhosts/10-enabled.conf@@state/nginx-vhosts/00-enabled.conf'
  'http2: проверка образа всегда молчит (A16)@@platform/lib/lib-stacks.sh@@        printf '"'"'image %s is older than 1.25.1@@        true \&\& printf '"'"'' # '"'"'image %s is older than 1.25.1'
  'фикстуры: окружение не заводится, блок пропускается (C6)@@platform/bin/selftest.sh@@  fixture_machine "$src" "$m"@@  true'
  'shellcheck: директива source= не резолвится (C5)@@platform/bin/certs.sh@@# shellcheck source=platform/lib/lib-stacks.sh@@# shellcheck source=../lib/lib-stacks.sh'
  # bootstrap сетью selftest не проверяет: прогон не должен зависеть от
  # интернета. Его проверяют руками, см. README.
  'sudo -u теряет ROOT_DIR@@platform/bin/host-setup.sh@@sudo -u "$SERVICE_USER" env ROOT_DIR="$ROOT_DIR" "$DIR0/certs.sh"@@sudo -u "$SERVICE_USER" "$DIR0/certs.sh"'
  'менеджер пакетов снова зашит@@platform/bin/host-setup.sh@@      apt-get) apt-get update -qq \&\& apt-get install -y "${MISSING_PKGS[@]}" ;;  # pkg-mgr-ok@@      apt-get) dnf install -y "${MISSING_PKGS[@]}" ;;'
  'статика: собирается по включённым@@platform/lib/lib-stacks.sh@@  done < <(stacks_available)\n\n  cat <<@@  done < <(stacks_enabled)\n\n  cat <<'

  # --- блок B: команда, которой на чужой машине нет или она ведёт себя иначе.
  'время: BSD-дата разбирает UTC как локальное (B3)@@platform/lib/lib-env.sh@@  date -j -f '"'"'%Y-%m-%dT%H:%M:%S%z'"'"' "$s" +%s 2>/dev/null \&\& return 0@@  date -j -f '"'"'%Y-%m-%dT%H:%M:%S'"'"' "${s%%%%[+-][0-9][0-9][0-9][0-9]}" +%s 2>/dev/null \&\& return 0'
  'суммы: голый shasum вместо обёртки (B4)@@platform/bin/check-vendor.sh@@  if [ "$(sha256_file "$f")" != "$sum" ]; then@@  if [ "$(shasum -a 256 "$f" | cut -d'"'"' '"'"' -f1)" != "$sum" ]; then'
  'bash: гарда версии снята (B5)@@platform/lib/lib-env.sh@@if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] ||@@if false \&\& [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] ||'
  'аргументы: $2 без ${2-} под set -u (B8)@@bin/pin.sh@@    --version) WANT="${2-}"; [ -n "$WANT" ] || { echo "Error: --version requires a value" >\&2; exit 2; }; shift 2 ;;@@    --version) WANT="$2"; shift 2 ;;'
  'сторож: timeout зовётся напрямую@@platform/bin/stack.sh@@            run_with_timeout "$HEALTH_TIMEOUT" "$hscript" 2>\&1)" || hrc=$?@@            timeout "$HEALTH_TIMEOUT" "$hscript" 2>\&1)" || hrc=$?'
  'сторож: фолбэк не отдаёт 124@@platform/lib/lib-env.sh@@  [ "$rc" -eq 143 ] \&\& rc=124@@  true'
  'find: снова -printf (только GNU)@@platform/bin/backup.sh@@  done < <(find "$TMP_DIR" -maxdepth 1 -type f ! -name '"'"'*.part'"'"' 2>/dev/null)@@  done < <(find "$TMP_DIR" -maxdepth 1 -type f -printf '"'"'%p '"'"' 2>/dev/null)'
  'аудит: дубликат у машины с самой собой (B7)@@bin/audit-isolation.sh@@if ($1 == prev \&\& $2 != prevm) print prevm@@if ($1 == prev) print prevm'

  # --- getssl больше не лежит копией: ссылки на неё не должны возвращаться.
  'getssl: юнит снова зовёт копию из платформы@@platform/systemd/getssl-renew.service@@ExecStart=@DEPLOY_DIR@/state/bin/getssl@@ExecStart=@DEPLOY_DIR@/platform/getssl'
  'getssl: сумма в lock обрезана@@platform/getssl.lock@@sha256=c26d1a714fb96feeed2ac808cf16aae8e453d0005475e47e5732213ab1a7485e@@sha256=c26d1a714fb96feeed2ac808'

  # --- корень машины из-под симлинка platform/ и флаги htpasswd.
  'корень: ROOT_DIR остаётся в .stackyard@@platform/bin/htpasswd.sh@@  [ "${ROOT_DIR##*/}" = .stackyard ] \&\& ROOT_DIR="${ROOT_DIR%/*}"@@  true'
  'htpasswd: -b вместе с -i (usage вместо пароля)@@platform/bin/htpasswd.sh@@FLAGS="-iB"@@FLAGS="-ibB"'
  'htpasswd: права ставит хост, а не контейнер@@platform/bin/htpasswd.sh@@  sh -c "$IN_CONTAINER"@@  sh -c "$IN_CONTAINER"\n\nchmod 640 "$FILE"'
  'nginx: образ зашит мимо nginx_image@@platform/bin/htpasswd.sh@@"$(nginx_image)"@@nginx:1.30-alpine'

  # --- устаревший bind-mount после ./bootstrap.
  'mount: пустой хост тоже считается уликой@@platform/lib/lib-stacks.sh@@  [ "${1:-0}" -gt 0 ] \&\& [ "${2:-0}" -eq 0 ]@@  [ "${2:-0}" -eq 0 ]'
  'mount: улика не распознаётся вовсе@@platform/lib/lib-stacks.sh@@  [ "${1:-0}" -gt 0 ] \&\& [ "${2:-0}" -eq 0 ]@@  false'

  # --- переименование генерируемого файла, не дошедшее до потребителей (A15).
  'compose: файл монтируется внутрь :ro-каталога@@platform/compose/nginx.yaml@@      - ${Platform_Deploy_Dir:?}/state/nginx-vhosts:/etc/nginx/enabled:ro@@      - ${Platform_Deploy_Dir:?}/state/nginx-vhosts/10-enabled.conf:/etc/nginx/conf.d/10-enabled.conf:ro'
  'vhost: посторонний каталог не замечается@@platform/lib/lib-stacks.sh@@    [ -f "$e" ] \&\& continue@@    continue'
  'vhost: проверка каталога не вызывается перед записью@@platform/bin/stack.sh@@  junk="$(check_vhost_dir "$(dirname "$file")")"@@  junk=""'
  'compose: каталог состояния не монтируется вовсе@@platform/compose/nginx.yaml@@      - ${Platform_Deploy_Dir:?}/state/nginx-vhosts:/etc/nginx/enabled:ro@@      - ${Platform_Deploy_Dir:?}/nginx:/etc/nginx/enabled:ro'
  'nginx: платформа не читает каталог состояния@@platform/nginx-vhosts/05-enabled.conf@@include /etc/nginx/enabled/*.conf;@@# include убран'
  'генератор: имя сверяется образцом@@platform/bin/docker-compose.sh@@  if [ "$gen" = "$(stacks_static_file)" ]; then@@  case "$gen" in *00-enabled.conf) :;; esac\n  if [ "$gen" = "$(stacks_static_file)" ]; then'
  'compose: имя генерируемого файла написано второй раз@@platform/bin/docker-compose.sh@@  -f "$STATIC_REL"@@  -f state/nginx-static.generated.yaml'
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
