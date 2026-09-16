#!/usr/bin/env bash

# Включение и выключение стеков девбокса — одной командой вместо трёх ручных
# шагов.
#
# Источник правды один — Enabled_Stacks в .env-stacks. Этот скрипт приводит к
# нему и compose, и nginx, и в правильном порядке: при включении сначала
# приложение, потом vhost; при выключении сначала vhost, потом смерть
# контейнеров. Ни в одной точке у nginx нет vhost'а без живого upstream'а.
#
# Руками те же шаги — правка compose-файлов, vhost'ов и контейнеров порознь —
# означают три места без общего источника правды: разъезд между ними даёт
# `host not found in upstream`, краш-луп nginx и все сайты машины разом
# (CLAUDE.md §3.1).
#
#   ./stack list                # что включено и что реально живо
#   ./stack enable  <стек>...   # включить и поднять
#   ./stack disable <стек>...   # остановить: данные и образы целы
#   ./stack purge   <стек>      # + тома и образы; спросит подтверждение
#   ./stack sync                # привести nginx к манифесту
#   ./stack --check             # только проверка, ненулевой код
#
# Флаги: --dry-run (показать команды, ничего не делать),
#        --no-start (только конфиг, контейнеры не поднимать) — для enable.
#
# Чего скрипт НЕ делает НИКОГДА, ни в одном режиме: не трогает данные в
# bind-mount'ах (/mnt/data/mysql и прочие) и не удаляет базы из общего
# MySQL. Освобождение места по этой части — руками, командами, которые
# `purge` печатает.

set -euo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Каталог МАШИНЫ, а не платформы. Обычно его задаёт обёртка ./stack в корне
# машины; запасной вариант — на два уровня вверх от platform/bin, чтобы скрипт
# работал и при прямом вызове.
if [ -z "${ROOT_DIR:-}" ]; then
  ROOT_DIR="$( cd "$DIR0/../.." && pwd )"
  # На машине platform/ — симлинк в .stackyard/, и `cd -P` выше его уже
  # развернул: два уровня приводят не в машину, а в .stackyard. Тогда state/
  # заводится ВНУТРИ скачиваемого слоя и пропадает при следующем ./bootstrap,
  # а до того htpasswd, сертификаты и databases.yaml лежат не там, где их ищут
  # контейнеры. Обёртки в корне машины ROOT_DIR задают сами, но документация
  # каждого скрипта зовёт его как ./platform/bin/<имя>.sh — этот путь и чиним.
  [ "${ROOT_DIR##*/}" = .stackyard ] && ROOT_DIR="${ROOT_DIR%/*}"
fi
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"

# shellcheck source=platform/lib/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"
# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"

MANIFEST="$ROOT_DIR/.env-stacks"

# Каталоги состояния — до любой команды, которая в них пишет. На свежей машине
# их нет вовсе, и первая же запись умирала сырой ошибкой оболочки.
ensure_state_dirs
DRY_RUN=0
NO_START=0
NO_UNITS=0
PROBLEMS=0
WARNINGS=0

# Предел для stacks/<стек>/scripts/health.sh. Проверка живости обязана быть
# быстрой: --check зовут и руками, и из мониторинга, и зависший скрипт стека
# подвесил бы весь отчёт вместе с ним.
HEALTH_TIMEOUT=10

ok()   { printf '  [ok]   %s\n' "$1"; }
warn() { printf '  [!]    %s\n' "$1"; WARNINGS=$((WARNINGS + 1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; PROBLEMS=$((PROBLEMS + 1)); }
step() { printf '\n== %s\n' "$1"; }
die()  { echo "Ошибка: $*" >&2; exit 1; }

# Всё, что меняет машину, проходит через run(): так --dry-run покрывает и
# docker, и запись файлов, и его не нужно вспоминать в каждой ветке.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry] %s\n' "$*"
    return 0
  fi
  "$@"
}

# Привести юниты systemd к манифесту.
#
# Ставит и снимает их systemd.sh, и только он: он один знает про плейсхолдеры,
# OnFailure и preflight стека. Здесь решается лишь то, нужен ли его вызов, — и
# делается он под root, потому что /etc/systemd/system иначе не тронуть.
#
# Если root'а нет, операция НЕ отменяется: стек уже выключен или включён, а
# юниты остаются расхождением, которое назовёт `--check`. Молча оставить его
# нельзя — забытый таймер выключенного стека будит машину каждую ночь, и
# снаружи это выглядит как исправная работа.
units_apply() {
  local reason="$1" cmd=("$DIR0/systemd.sh")
  [ "$(id -u)" -eq 0 ] || cmd=(sudo "${cmd[@]}")

  if [ "$NO_UNITS" -eq 1 ]; then
    warn "--no-units: юниты не тронуты — ${cmd[*]}"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry] %s\n' "${cmd[*]}"
    return 0
  fi
  if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
    warn "нет sudo — юниты остались как были: ${cmd[*]}"
    return 0
  fi

  echo "  $reason"
  if "${cmd[@]}" 2>&1 | sed 's/^/      /'; then
    ok "юниты соответствуют манифесту"
  else
    warn "systemd.sh не отработал — повторить руками: ${cmd[*]}"
  fi
}

# Строка таблицы стеков. Ширины заданы один раз здесь, чтобы шапка и данные не
# разъехались при правке.
_row() {
  printf '%s%s%s%s%s\n' \
    "$(_cell "$1" 13)" "$(_cell "$2" 10)" "$(_cell "$3" 22)" "$(_cell "$4" 14)" "$5"
}

usage() {
  cat <<'USAGE'
Включение и выключение стеков девбокса. Источник правды — Enabled_Stacks
в .env-stacks; этот скрипт приводит к нему и docker compose, и nginx.

  stack.sh list                 что включено, что реально запущено, что с vhost'ами
  stack.sh enable  <стек>...    включить: манифест -> контейнеры -> vhost -> юниты
  stack.sh disable <стек>...    выключить: манифест -> юниты -> vhost -> контейнеры
                                (тома, образы и данные целы; enable вернёт как было)
  stack.sh purge   <стек>       + удалить тома и образы; необратимо, спросит имя стека
                                (данные в bind-mount'ах и базы в общем MySQL — нет)
  stack.sh sync                 привести vhost'ы nginx к манифесту (после git pull)
  stack.sh --check              только проверка, код 1 при проблемах

  --dry-run     показать, что будет сделано, и ничего не делать
  --no-start    для enable: только конфигурация, контейнеры не поднимать
  --no-units    не трогать юниты systemd (иначе enable/disable зовут
                sudo ./platform/bin/systemd.sh сами; расхождение ловит --check)

Почему так устроено — docs/architecture/stack-toggle-design.md
USAGE
  exit "${1:-2}"
}

# ---------------------------------------------------------------- манифест

# Перезапись Enabled_Stacks с сохранением остального файла: комментарии в
# .env-stacks объясняют, как им пользоваться, и стирать их при каждом enable
# было бы обидно.
manifest_write() {
  local stacks="$*" tmp
  # С этого момента все производные (include'ы nginx, проверки зависимостей)
  # считаются от НОВОГО состава — и в обычном режиме, и под --dry-run.
  STACKS_ENABLED_OVERRIDE="$stacks"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry] Enabled_Stacks="%s" (файл не тронут)\n' "$stacks"
    return 0
  fi
  tmp=$(mktemp)
  if [ -f "$MANIFEST" ] && grep -qE '^[[:space:]]*Enabled_Stacks=' "$MANIFEST"; then
    awk -v val="Enabled_Stacks=\"$stacks\"" '
      /^[[:space:]]*Enabled_Stacks=/ { if (!done) { print val; done = 1 } next }
      { print }
    ' "$MANIFEST" > "$tmp"
  else
    [ -f "$MANIFEST" ] && cat "$MANIFEST" > "$tmp"
    {
      [ -f "$MANIFEST" ] || cat "$ROOT_DIR/.env-stacks.example" 2>/dev/null | sed '/^Enabled_Stacks=/d'
      printf 'Enabled_Stacks="%s"\n' "$stacks"
    } >> "$tmp"
  fi
  cat "$tmp" > "$MANIFEST"
  rm -f "$tmp"
  ok "Enabled_Stacks: $stacks"
}

# ------------------------------------------------------------------ nginx

nginx_running() {
  [ "$(docker inspect -f '{{.State.Status}}' nginx 2>/dev/null || true)" = "running" ]
}

# Список баз общего MySQL — из деклараций включённых стеков.
#
# Отдельной функцией, а не строкой в nginx_apply: к nginx это отношения не
# имеет, а вызывается оттуда лишь потому, что там же собраны все генерируемые
# файлы. Права 600 обязательны — внутри пароли.
databases_apply() {
  local f content
  f="$(stacks_databases_file)"
  # Пусто — значит поставщик не включён. Это законное состояние: машине с одним
  # прокси-стеком общая СУБД не нужна. Проверка на КАТАЛОГ здесь не годилась:
  # dirname от пустой строки даёт ".", он существует всегда, и дальше шло
  # `> ""` — сырая ошибка оболочки на первой же команде такой машины.
  [ -n "$f" ] || { ok "поставщика общей БД нет — списку баз неоткуда взяться"; return 0; }
  mkdir -p "$(dirname "$f")"
  content="$(stacks_databases_content)"
  if [ -f "$f" ] && [ "$(cat "$f")" = "$content" ]; then
    ok "базы MySQL уже соответствуют декларациям"
  elif [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry] перезаписать %s\n' "$f"
  else
    printf '%s' "$content" > "$f"
    chmod 600 "$f"
    ok "перезаписан $(basename "$f") (chmod 600)"
  fi
}

# Пересобрать include-файл и перезагрузить nginx. Именно перезагрузить, а не
# пересоздать контейнер: каталог vhost'ов смонтирован с хоста, а пересоздание —
# это отдельный способ уронить все сайты (CLAUDE.md §3.1).
#
# `nginx -t` до reload и откат include-файла при неудаче — потому что reload на
# битом конфиге nginx просто не применяет его и продолжает жить со старым, а
# вот следующий рестарт контейнера по любой причине уже не поднимется.
nginx_apply() {
  local file backup content static_file static_content
  file="$(stacks_include_file)"
  content="$(stacks_include_content)"

  # Статика — первой. Она попадает в СПЕКУ nginx, то есть её изменение
  # заставляет следующий `up -d` пересоздать контейнер; include'ы читает уже
  # запущенный nginx по reload. Порядок вывода отражает это различие: сначала
  # то, из-за чего nginx может быть пересоздан, потом то, из-за чего он будет
  # всего лишь перезагружен.
  #
  # Содержимое считается по ВСЕМ стекам, поэтому здесь оно меняется только при
  # правке stack.conf, а не при enable/disable — см. stacks_static_content().
  static_file="$(stacks_static_file)"
  static_content="$(stacks_static_content)"
  if [ -f "$static_file" ] && [ "$(cat "$static_file")" = "$static_content" ]; then
    ok "статика nginx уже соответствует декларациям"
  elif [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry] перезаписать %s\n' "$static_file"
  else
    mkdir -p "$(dirname "$static_file")"
    printf '%s' "$static_content" > "$static_file"
    ok "перезаписан $(basename "$static_file")"
  fi

  databases_apply

  if [ -f "$file" ] && [ "$(cat "$file")" = "$content" ]; then
    ok "vhost'ы nginx уже соответствуют манифесту"
  else
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '  [dry] перезаписать %s:\n' "$file"
      printf '%s\n' "$content" | grep '^include' | sed 's/^/          /'
    else
      backup=$(mktemp)
      [ -f "$file" ] && cat "$file" > "$backup"
      printf '%s\n' "$content" > "$file"
      ok "перезаписан $(basename "$file")"
    fi
  fi

  certs_stubs_if_needed

  if ! nginx_running; then
    warn "контейнер nginx не запущен — перезагружать нечего; поднимите его: ./dc up -d nginx"
    [ -n "${backup:-}" ] && rm -f "$backup"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry] docker exec nginx nginx -t && docker exec nginx nginx -s reload\n'
    return 0
  fi

  if ! docker exec nginx nginx -t >/dev/null 2>&1; then
    echo "  [FAIL] nginx -t не прошёл, откатываю $(basename "$file")" >&2
    docker exec nginx nginx -t || true
    if [ -n "${backup:-}" ] && [ -s "$backup" ]; then
      cat "$backup" > "$file"
    else
      rm -f "$file"
    fi
    [ -n "${backup:-}" ] && rm -f "$backup"
    die "конфиг nginx не собрался; изменения в vhost'ах откачены, контейнеры не тронуты"
  fi
  # Не `rm -f "${backup:-}"`: с пустым аргументом rm возвращает 1, и под set -e
  # это оборвало бы скрипт ровно перед reload — в самом неудачном месте.
  [ -n "${backup:-}" ] && rm -f "$backup"

  docker exec nginx nginx -s reload
  ok "nginx перезагружен"
}

# Заглушки сертификатов — ДО того, как nginx увидит новый vhost, иначе он не
# стартует (CLAUDE.md §6). Запускаем certs.sh только если чего-то реально не
# хватает: генерация dhparam на пустом месте занимает минуты.
certs_stubs_if_needed() {
  local certs_dir="$ROOT_DIR/state/certs" missing=0 path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -f "$certs_dir/$(basename "$path")" ] || missing=1
  done < <(stacks_cert_paths | awk '{print $2}' | tr -d ';' | sort -u)

  [ "$missing" -eq 0 ] && return 0
  warn "не хватает файлов сертификатов — запускаю platform/bin/certs.sh (заглушки)"
  run "$DIR0/certs.sh"
}

# ------------------------------------------------------------- контейнеры

# Все контейнеры стека (включая остановленные), по меткам compose.
stack_containers() {
  local s="$1" svc
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    service_containers "$svc"
  done < <(stack_services "$s" 2>/dev/null)
}

stack_running() {
  local s="$1" id n=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null)" = "running" ] && n=$((n + 1))
  done < <(stack_containers "$s")
  printf '%s' "$n"
}

# Удаление контейнеров стека.
#
# Именно удаление, а не `stop`: watch-host.sh обходит `docker ps -a` и на
# остановленный контейнер с `restart: always` присылает crit-оповещение. То
# есть выключенный стек круглосуточно выглядел бы аварией.
#
# И именно `docker rm -f` по меткам, а не `docker compose rm`: к этому моменту
# стек уже вычеркнут из манифеста, его файл больше не подключается, и просить
# compose об удалении нечем. Метки compose при этом на месте — они на самих
# контейнерах.
containers_remove() {
  local s="$1" ids
  ids=$(stack_containers "$s" | tr '\n' ' ')
  ids=$(echo $ids)
  if [ -z "$ids" ]; then
    ok "контейнеров стека '$s' нет"
    return 0
  fi
  # shellcheck disable=SC2086
  run docker rm -f $ids
  ok "удалены контейнеры: $(echo $ids | wc -w | tr -d ' ') шт."
}

# ---------------------------------------------------------------- verbs

verb_list() {
  local s enabled_list missing running vhosts mark files
  enabled_list=" $(stacks_enabled 2>/dev/null | tr '\n' ' ') "

  _row "СТЕК" "МАНИФЕСТ" "ФАЙЛЫ" "КОНТЕЙНЕРЫ" "VHOSTS"
  while IFS= read -r s; do
    case "$enabled_list" in *" $s "*) mark="вкл" ;; *) mark="выкл" ;; esac

    missing="$(stack_missing_files "$s" | tr '\n' ',' | sed 's/,$//')"
    files="ок"; [ -n "$missing" ] && files="нет: $missing"

    running="$(stack_running "$s")"
    total="$(stack_services "$s" 2>/dev/null | grep -c . || true)"

    vhosts="—"
    if [ -d "$(stack_vhost_dir "$s")" ]; then
      n=$(ls -1 "$(stack_vhost_dir "$s")"/*.conf 2>/dev/null | grep -c . || true)
      if [ "$n" -gt 0 ]; then
        if stack_vhost_enabled "$s"; then
          vhosts="$n (вкл)"
        else
          vhosts="$n (выкл)"
        fi
      fi
    fi

    _row "$s" "$mark" "$files" "$running/$total" "$vhosts"
  done < <(stacks_available)

  printf '\nМанифест: %s\n' "$([ -f "$MANIFEST" ] && echo "$MANIFEST" || echo 'НЕТ (считаются включёнными все стеки с полным набором файлов)')"
}

verb_enable() {
  local want=() s req add enabled_now new_list svc_args=()
  want=("$@")

  for s in "${want[@]}"; do
    stack_exists "$s" || die "нет такого стека: '$s' (см. ./stack list)"
  done

  # Зависимости добавляем сами: включить timesheets без mysql — это не выбор, а
  # забытый шаг, и проявляется он контейнером, который не стартует.
  for s in "${want[@]}"; do
    for req in $(stack_requires "$s"); do
      case " ${want[*]} " in *" $req "*) continue ;; esac
      if ! stack_is_enabled "$req"; then
        echo "Стеку '$s' нужен '$req' — включаю и его."
        want+=("$req")
      fi
    done
  done

  for s in "${want[@]}"; do
    missing="$(stack_missing_files "$s" | tr '\n' ' ')"
    [ -n "$(echo $missing)" ] && die "стеку '$s' не хватает файлов: $missing"
  done

  enabled_now="$(stacks_enabled 2>/dev/null | tr '\n' ' ')"
  new_list="$enabled_now"
  for s in "${want[@]}"; do
    case " $new_list " in *" $s "*) echo "Стек '$s' уже включён — довожу состояние." ;; *) new_list="$new_list $s" ;; esac
  done

  step "Манифест"
  manifest_write $(echo $new_list)

  # Декларации баз — ДО контейнеров: инициализатор читает databases.yaml в
  # момент старта, и сгенерируй мы файл позже (в nginx_apply, как обычно),
  # инициализатор отработал бы по прежнему списку.
  step "Базы общего MySQL"
  databases_apply

  # Сначала приложение, потом vhost. Обратный порядок — это nginx с
  # proxy_pass на несуществующий контейнер, то есть краш-луп и все сайты.
  if [ "$NO_START" -eq 1 ]; then
    step "Контейнеры"
    warn "--no-start: контейнеры не поднимаю"
  else
    step "Контейнеры"
    for s in "${want[@]}"; do
      while IFS= read -r svc; do
        [ -n "$svc" ] && svc_args+=("$svc")
      done < <(stack_services "$s")
    done

    # Стек с объявленной базой без пользователя и базы в общем MySQL не
    # работает, а заводит их инициализатор — одноразовый контейнер поставщика.
    # Сам поставщик при этом чаще всего уже включён, в список поднимаемых не попадает,
    # и приложение стартует с DATABASE_URL на несуществующую базу: рестарты и
    # `Access denied for user` в его логах.
    for s in "${want[@]}"; do
      [ -n "$(stack_conf_get "$s" "$(stacks_db_prefix)_DB")" ] || continue
      case " ${svc_args[*]} " in
        *" $(stacks_db_init_service) "*) ;;
        *) svc_args+=("$(stacks_db_init_service)") ;;
      esac
      break
    done

    if [ ${#svc_args[@]} -eq 0 ]; then
      warn "у стеков не нашлось сервисов — нечего поднимать"
    else
      run env STACK_SH_APPLYING=1 "$DIR0/docker-compose.sh" up -d "${svc_args[@]}"
    fi
  fi

  step "nginx"
  nginx_apply

  # Юниты ставим ПОСЛЕ контейнеров и vhost'а: таймер стека зовёт скрипты,
  # которым нужен живой стек, и сработавший раньше времени даёт оповещение об
  # аварии на ровном месте.
  step "Юниты systemd"
  local need_units=0 u
  for s in "${want[@]}"; do
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      stack_units_installed "$s" | grep -qxF "$(basename "$u")" || need_units=1
    done < <(stack_units "$s")
  done
  if [ "$need_units" -eq 1 ]; then
    units_apply "ставлю юниты включённых стеков…"
  else
    ok "юниты этих стеков уже на месте"
  fi
}

verb_disable() {
  local want=("$@") s dep deps new_list

  for s in "${want[@]}"; do
    stack_exists "$s" || die "нет такого стека: '$s' (см. ./stack list)"
  done

  # Не даём выключить стек, на котором стоят другие включённые. Иначе это
  # выглядит как «выключил mysql», а обнаруживается как «timesheets перестал
  # помнить» через неделю.
  for s in "${want[@]}"; do
    deps=""
    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      case " ${want[*]} " in *" $dep "*) continue ;; esac
      deps="$deps $dep"
    done < <(stack_dependents "$s")
    [ -n "$(echo $deps)" ] && die "стек '$s' нужен включённым стекам:$deps — выключайте вместе или сначала их"
  done

  new_list=""
  for s in $(stacks_enabled 2>/dev/null); do
    case " ${want[*]} " in *" $s "*) continue ;; esac
    new_list="$new_list $s"
  done

  step "Манифест"
  manifest_write $(echo $new_list)

  # Юниты снимаем ДО контейнеров: таймер, сработавший между смертью контейнера
  # и снятием юнита, запустит скрипт по мёртвому стеку — и пришлёт оповещение
  # об аварии, которой нет. Манифест к этому моменту уже новый, поэтому
  # systemd.sh сам считает эти стеки выключенными.
  step "Юниты systemd"
  local installed=""
  for s in "${want[@]}"; do
    installed="$installed$(stack_units_installed "$s")"
  done
  if [ -n "$installed" ]; then
    units_apply "снимаю юниты выключаемых стеков…"
  else
    ok "установленных юнитов у этих стеков нет"
  fi

  # Сначала vhost, потом контейнеры: в обратном порядке у nginx между шагами
  # остаётся vhost с мёртвым upstream'ом, и любой рестарт в этом окне уносит
  # все сайты.
  step "nginx"
  nginx_apply

  step "Контейнеры"
  for s in "${want[@]}"; do
    containers_remove "$s"
  done

  step "Что осталось на месте"
  for s in "${want[@]}"; do
    # `|| true`: purge_plan возвращает 1, когда удалять нечего, и под set -e
    # это оборвало бы disable ровно на последнем, информационном шаге.
    purge_plan "$s" report || true
  done
  echo
  echo "Данные, тома и образы не тронуты — включение обратно: ./stack enable ${want[*]}"
  echo "Освободить место (необратимо): ./stack purge <стек>"
}

# Репозиторий образа без тега. Значения вида php5.6-fpm:${Php_Image_Tag:-latest}
# ломают наивное «отрезать после последнего двоеточия», поэтому сначала
# отрезаем подстановку.
image_repo() {
  local v="$1"
  if [[ "$v" == *'${'* ]]; then v="${v%%\$\{*}"; v="${v%:}"; fi
  case "${v##*:}" in
    "$v") printf '%s' "$v" ;;
    */*)  printf '%s' "$v" ;;
    *)    printf '%s' "${v%:*}" ;;
  esac
}

# Образы стека, за вычетом тех, на которые ссылается кто-то ещё. Общий базовый
# образ (mysql, nginx) не должен исчезнуть из-за purge одного стека.
stack_own_images() {
  local s="$1" other="" o img repo proj svc
  while IFS= read -r o; do
    [ "$o" = "$s" ] && continue
    while IFS= read -r img; do
      [ -n "$img" ] && other="$other $(image_repo "$img")"
    done < <(stack_images "$o")
  done < <(stacks_available)
  while IFS= read -r img; do
    [ -n "$img" ] && other="$other $(image_repo "$img")"
  done < <(awk '/^[[:space:]]+image:[[:space:]]*[^[:space:]]/ { print $2 }' \
              "$ROOT_DIR/platform/compose/nginx.yaml" "$ROOT_DIR/platform/compose/nginx-static.generated.yaml" 2>/dev/null)

  # Кандидаты: объявленные `image:` плюс имена, которые compose даёт образам,
  # собранным из `build:` без `image:`. Без этого
  # purge оставлял бы на диске самое крупное, что стек занимает.
  {
    stack_images "$s"
    proj="$(compose_project)"
    while IFS= read -r svc; do
      [ -n "$svc" ] || continue
      printf '%s-%s\n' "$proj" "$svc"   # compose v2
      printf '%s_%s\n' "$proj" "$svc"   # compose v1, если образ остался с тех времён
    done < <(stack_services "$s" 2>/dev/null)
  } | while IFS= read -r img; do
    [ -n "$img" ] || continue
    repo="$(image_repo "$img")"
    case " $other " in *" $repo "*) continue ;; esac
    printf '%s\n' "$repo"
  done | sort -u
}

# Тома стека, как они реально называются в docker.
stack_docker_volumes() {
  local s="$1" v proj found
  proj="$(compose_project)"
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    found=$(docker volume ls -q \
              --filter "label=com.docker.compose.project=$proj" \
              --filter "label=com.docker.compose.volume=$v" 2>/dev/null || true)
    if [ -z "$found" ] && docker volume inspect "${proj}_${v}" >/dev/null 2>&1; then
      found="${proj}_${v}"
    fi
    [ -n "$found" ] && printf '%s\n' "$found"
  done < <(stack_volumes "$s")
}

# Печатает, что purge удалит. mode=report — только перечислить.
purge_plan() {
  local s="$1" mode="${2:-plan}" v repo line n
  n=0

  while IFS= read -r v; do
    [ -n "$v" ] || continue
    printf '  том   %-42s %s\n' "$v" "$(docker volume inspect -f '{{.Mountpoint}}' "$v" 2>/dev/null || true)"
    n=$((n + 1))
  done < <(stack_docker_volumes "$s")

  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] && printf '  образ %s\n' "$line" && n=$((n + 1))
    done < <(docker images --filter "reference=$repo" --format '{{.Repository}}:{{.Tag}}  {{.Size}}' 2>/dev/null | sort -u)
  done < <(stack_own_images "$s")

  if [ "$n" -eq 0 ]; then
    [ "$mode" = "report" ] && printf '  стек %s: томов и образов не найдено\n' "$s"
    return 1
  fi
  return 0
}

verb_purge() {
  local s="$1" answer v repo

  stack_exists "$s" || die "нет такого стека: '$s' (см. ./stack list)"

  step "Будет удалено НЕОБРАТИМО (стек '$s')"
  local containers
  containers=$(stack_containers "$s" | grep -c . || true)
  printf '  контейнеров: %s\n' "$containers"
  purge_plan "$s" || true

  step "Останется на месте"
  echo "  * данные в bind-mount'ах (/mnt/data/...) — этот скрипт их не трогает никогда"
  echo "  * базы в общем MySQL. Если нужно освободить и их, ВРУЧНУЮ:"
  echo "      cd _db && ./dbquery.sh 'DROP DATABASE \`<имя>\`;'"
  echo "      cd _db && ./dbquery.sh \"DROP USER '<имя>'@'%';\""
  echo "  * чекаут приложения в ~/dev/ и build cache докера"
  echo "      (кэш сборки чистится отдельно: docker builder prune)"

  if [ "$DRY_RUN" -eq 1 ]; then
    step "--dry-run: подтверждение не спрашиваю, ничего не делаю"
    return 0
  fi

  # Подтверждение вводом имени стека, а не [y/N]: purge необратим, а «y»
  # нажимается на автопилоте. Ввести имя того стека, который сейчас исчезнет, —
  # ровно та пауза, которая здесь нужна.
  if [ ! -t 0 ]; then
    die "purge требует интерактивного терминала (подтверждение вводом имени стека)"
  fi
  step "Подтверждение"
  printf 'Введите имя стека для подтверждения (%s), либо Enter для отмены: ' "$s"
  IFS= read -r answer
  [ "$answer" = "$s" ] || die "отменено (введено '$answer')"

  # Сначала обычное выключение: манифест, nginx, контейнеры. Тома нельзя
  # удалить, пока их держит контейнер, а vhost нельзя оставить без upstream'а.
  if stack_is_enabled "$s"; then
    verb_disable "$s"
  else
    step "Контейнеры"
    containers_remove "$s"
  fi

  step "Тома"
  while IFS= read -r v; do
    [ -n "$v" ] && run docker volume rm "$v"
  done < <(stack_docker_volumes "$s")

  step "Образы"
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    while IFS= read -r img; do
      [ -n "$img" ] && run docker rmi "$img"
    done < <(docker images --filter "reference=$repo" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sort -u)
  done < <(stack_own_images "$s")

  step "Готово"
  df -h /var/lib/docker 2>/dev/null | tail -n 1 || true
  echo "Стек '$s' выпилен. Вернуть: ./stack enable $s (пересборка образа обязательна)"
}

verb_sync() {
  step "nginx"
  nginx_apply

  step "Расхождения с манифестом"
  local s running total
  while IFS= read -r s; do
    running="$(stack_running "$s")"
    total="$(stack_services "$s" 2>/dev/null | grep -c . || true)"
    if [ "$running" -eq 0 ] && [ "$total" -gt 0 ]; then
      warn "включён, но не запущен: $s — ./stack enable $s"
    fi
  done < <(stacks_enabled 2>/dev/null)

  while IFS= read -r s; do
    stack_is_enabled "$s" && continue
    running="$(stack_containers "$s" | grep -c . || true)"
    [ "$running" -gt 0 ] && warn "выключен, но остались контейнеры ($running): $s — ./stack disable $s"
  done < <(stacks_available)

  [ "$WARNINGS" -eq 0 ] && ok "расхождений нет"
}

verb_check() {
  local s line fn up pair missing include_file awk_svc cfg_svc decl_problems_before
  local db_file perm init_state init_svc img_problem zone_problem

  step "Манифест"
  if [ -f "$MANIFEST" ]; then
    ok ".env-stacks на месте"
    ok "включено: $(stacks_enabled 2>/dev/null | tr '\n' ' ')"
  else
    warn "нет .env-stacks — включёнными считаются все стеки с полным набором файлов (cp .env-stacks.example .env-stacks)"
  fi

  step "Файлы включённых стеков"
  while IFS= read -r s; do
    missing="$(stack_missing_files "$s" | tr '\n' ' ')"
    if [ -n "$(echo $missing)" ]; then
      bad "$s: нет $missing — любая compose-команда падает"
    else
      ok "$s"
    fi
  done < <(stacks_enabled 2>/dev/null)

  step "Декларации стеков"
  while IFS= read -r s; do
    if [ -f "$(stack_conf_file "$s")" ]; then
      ok "$s: stack.conf есть"
    else
      bad "$s: нет stack.conf — стек ничего не объявляет о себе платформе"
    fi
  done < <(stacks_available)

  decl_problems_before="$PROBLEMS"
  while IFS= read -r line; do [ -n "$line" ] && bad "$line"; done < <(check_domains_unique)
  while IFS= read -r line; do [ -n "$line" ] && bad "$line"; done < <(check_databases_unique)

  while IFS= read -r s; do
    for fn in check_domains_match check_paths_absolute check_unit_names \
              check_timer_has_check check_no_base_service_merge check_requires_cycle \
              check_db_decl; do
      while IFS= read -r line; do [ -n "$line" ] && bad "$line"; done < <("$fn" "$s")
    done
    # Счётчик проблем на этот блок свой: общий PROBLEMS к этому моменту уже мог
    # вырасти на отсутствующих .env, и тогда «в порядке» не печаталось бы даже
    # при чистых декларациях.
    :
  done < <(stacks_enabled 2>/dev/null)
  if [ "$PROBLEMS" -eq "$decl_problems_before" ]; then
    ok "домены, пути, имена юнитов и зависимости в порядке"
  fi

  step "Образ nginx"
  # До всего остального, что касается nginx: с несовместимым образом он не
  # стартует вовсе, и все прочие находки про него бессмысленны.
  img_problem="$(check_nginx_image)"
  if [ -n "$img_problem" ]; then bad "$img_problem"; else ok "образ поддерживает директивы платформы"; fi

  zone_problem="$(check_limit_zones)"
  if [ -n "$zone_problem" ]; then
    printf '%s\n' "$zone_problem" | while IFS= read -r l; do [ -n "$l" ] && bad "$l"; done
    PROBLEMS=$((PROBLEMS + 1))
  else
    ok "все зоны лимитов, на которые ссылаются vhost'ы, определены"
  fi

  step "Статика nginx"
  # Расхождение между Nginx_Static_Sage_Dir в корневом .env и путём из .env
  # стека — единственная причина, по которой дублирование терпимо; без этой
  # проверки оно перестало бы быть терпимым.
  if [ ! -f "$(stacks_static_file)" ]; then
    bad "нет $(basename "$(stacks_static_file)") — ./stack sync"
  elif [ "$(cat "$(stacks_static_file)")" != "$(stacks_static_content)" ]; then
    bad "$(basename "$(stacks_static_file)") не соответствует stack.conf — ./stack sync"
  else
    ok "статика соответствует декларациям"
  fi

  step "Базы общего MySQL"
  # ENV_VARS после check_db_decl забит переменными последнего стека —
  # вернуть платформенное окружение, иначе всё, что читает .env ниже, увидит
  # чужие значения.
  ENV_VARS=(); env_load_files "$ROOT_DIR/.env" >/dev/null 2>&1 || true
  if [ -z "$(stacks_db_provider)" ]; then
    ok "поставщик общей БД не включён — базы заводить некому и незачем"
  else
    db_file="$(stacks_databases_file)"
    if [ ! -f "$db_file" ]; then
      bad "нет $(basename "$db_file") — $(stacks_db_init_service) не поднимется; ./stack sync"
    elif [ "$(cat "$db_file")" != "$(stacks_databases_content)" ]; then
      bad "$(basename "$db_file") не соответствует декларациям — ./stack sync"
    else
      ok "databases.yaml соответствует декларациям"
      # Права важны не меньше содержимого: внутри пароли всех баз машины.
      perm=$(stat -c '%a' "$db_file" 2>/dev/null || stat -f '%OLp' "$db_file")
      [ "$perm" = "600" ] || bad "$(basename "$db_file") имеет права $perm вместо 600 — внутри пароли"
    fi

    # У инициализатора нет `restart: always`, поэтому его падение снаружи не
    # видно: контейнер просто «exited». А падает он ровно тогда, когда пароль в
    # базе разошёлся с объявленным, — то есть сообщает о поломке, которую иначе
    # ловят по «Access denied» в логах приложения спустя часы.
    init_svc="$(stacks_db_init_service)"
    init_state=$(docker inspect -f '{{.State.Status}}:{{.State.ExitCode}}' "$init_svc" 2>/dev/null || true)
    case "$init_state" in
      '')            warn "контейнера $init_svc нет — поставщика ни разу не поднимали?" ;;
      exited:0)      ok "$init_svc отработал успешно" ;;
      running:*|created:*) warn "$init_svc ещё работает" ;;
      *)             bad "$init_svc завершился с кодом ${init_state#*:} — docker logs $init_svc" ;;
    esac
  fi

  step "Upstream'ы включённых vhost'ов"
  # Пересоздать nginx при опущенном upstream'е — это «host not found in
  # upstream», отказ старта и, с restart: always, краш-луп, уносящий ВСЕ
  # vhost'ы (CLAUDE.md §3.1). stack.sh поднимает контейнеры раньше vhost'а, но
  # заметить, что контейнер лежал ещё до начала, умеет только эта проверка.
  while IFS= read -r up; do
    [ -n "$up" ] || continue
    if [ "$(docker inspect -f '{{.State.Status}}' "$up" 2>/dev/null || true)" = "running" ]; then
      ok "upstream $up поднят"
    else
      bad "upstream $up не запущен — пересоздание nginx уронит ВСЕ vhost'ы"
    fi
  done < <(stacks_upstreams)

  step "vhost'ы nginx"
  include_file="$(stacks_include_file)"
  if [ ! -f "$include_file" ]; then
    bad "нет $(basename "$include_file") — nginx после следующей перезагрузки останется без ВСЕХ vhost'ов; ./stack sync"
  elif [ "$(cat "$include_file")" != "$(stacks_include_content)" ]; then
    bad "$(basename "$include_file") не соответствует манифесту — ./stack sync"
  else
    ok "include'ы соответствуют манифесту"
  fi

  if nginx_running; then
    if docker exec nginx nginx -t >/dev/null 2>&1; then
      ok "nginx -t проходит"
    else
      bad "nginx -t НЕ проходит — контейнер не поднимется при следующем рестарте"
    fi
  else
    bad "контейнер nginx не запущен"
  fi

  # Два вопроса про РАБОТАЮЩИЙ процесс, на которые `nginx -t` не отвечает.
  #
  # Первый: смонтировано ли в контейнер то, что написано в спеке. Правка
  # `volumes` применяется только пересозданием, а до него контейнер выглядит
  # исправным — и читает каталоги, которых на диске может уже не быть.
  #
  # Второй: обслуживает ли он хоть один домен. Конфигурация без единого
  # server-блока синтаксически верна, `nginx -t` её пропускает, и nginx с ней
  # не слушает вообще ничего — снаружи это неотличимо от выключенной машины, а
  # изнутри все прочие проверки зелёные.
  step "Живой nginx против спеки"
  if ! nginx_running; then
    warn "контейнер nginx не запущен — сверять нечего"
  else
    local live_mounts spec_mounts pair served declared dom mismatch=0
    live_mounts="$(docker inspect nginx \
      --format '{{range .Mounts}}{{.Source}}	{{.Destination}}{{"\n"}}{{end}}' 2>/dev/null || true)"
    spec_mounts="$(cd "$ROOT_DIR" && docker compose \
      --project-directory "$ROOT_DIR" --env-file "$ROOT_DIR/.env" \
      -f "$ROOT_DIR/platform/compose/nginx.yaml" -f "$(stacks_static_file)" \
      config 2>/dev/null | compose_mount_pairs || true)"

    # Обе стороны приводим к одному читаемому виду «источник -> цель»: дальше
    # сравниваются строки, и в сообщение попадает ровно то, что сравнивалось.
    live_mounts="$(printf '%s\n' "$live_mounts" | awk -F'\t' 'NF >= 2 { printf "%s -> %s\n", $1, $2 }' | sort)"
    spec_mounts="$(printf '%s\n' "$spec_mounts" | awk -F'\t' 'NF >= 2 { printf "%s -> %s\n", $1, $2 }' | sort)"

    if [ -z "$spec_mounts" ]; then
      warn "спека nginx не собралась — монтирования не сверить"
    else
      # Расхождение считается ОДНОЙ проблемой, а подробности идут строками
      # ниже: лечение у всех строк одно и то же, и повторять его у каждой
      # значило бы утопить в нём остальной отчёт.
      local detail=""
      while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        printf '%s\n' "$live_mounts" | grep -qxF "$pair" && continue
        mismatch=$((mismatch + 1))
        detail="$detail         нет в контейнере: $pair"$'\n'
      done <<< "$spec_mounts"
      while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        printf '%s\n' "$spec_mounts" | grep -qxF "$pair" && continue
        mismatch=$((mismatch + 1))
        detail="$detail         лишнее в контейнере: $pair"$'\n'
      done <<< "$live_mounts"
      if [ "$mismatch" -eq 0 ]; then
        ok "монтирования совпадают со спекой"
      else
        bad "монтирования разошлись со спекой ($mismatch) — ./dc up -d nginx"
        printf '%s' "$detail"
      fi

      # Путь монтирования и то, что по нему видно, — разные вещи, и сравнения
      # путей выше недостаточно. ./bootstrap заменяет .stackyard целиком
      # (rm -rf), а platform/ — симлинк туда: живой контейнер остаётся с
      # bind-mount'ом на УДАЛЁННЫЙ каталог. В docker inspect путь прежний, а
      # файлов внутри ноль.
      #
      # Снаружи это выглядит как ошибка во vhost'е — «open() snippets/
      # letsencrypt.conf failed (2: No such file or directory)», — и чинить
      # идут vhost, который ни при чём. Поэтому спрашиваем у контейнера, а не
      # у docker inspect.
      local src dst host_n cont_n empty=0
      while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        src="${pair%% -> *}"; dst="${pair##* -> }"
        [ -d "$src" ] || continue
        host_n=$(ls -A "$src" 2>/dev/null | wc -l | tr -d ' ')
        cont_n=$(docker exec nginx sh -c "ls -A '$dst' 2>/dev/null | wc -l" 2>/dev/null | tr -d ' \r')
        if mount_looks_stale "$host_n" "$cont_n"; then
          bad "контейнер не видит $dst — каталог на хосте подменили после запуска: ./dc up -d nginx"
          empty=$((empty + 1))
        fi
      done <<< "$spec_mounts"
      [ "$empty" -eq 0 ] && ok "контейнер видит содержимое смонтированных каталогов"
    fi

    served="$(docker exec nginx nginx -T 2>/dev/null | nginx_served_names)"
    # Здесь нужны ВСЕ имена, включая алиасы: именно их обслуживают server-блоки.
    # stacks_domains отдаёт только основные — ими меряют сертификаты, не vhost'ы.
    declared="$(stacks_domain_names)"
    if [ -z "$served" ]; then
      bad "работающий nginx не обслуживает НИ ОДНОГО домена — ./dc up -d nginx"
    else
      for dom in $declared; do
        printf '%s\n' "$served" | grep -qxF "$dom" \
          || bad "nginx не обслуживает $dom — у процесса конфигурация не та, что на диске: ./dc up -d nginx"
      done
      for dom in $served; do
        printf '%s\n' "$declared" | grep -qxF "$dom" \
          || warn "nginx обслуживает $dom, которого нет ни у одного включённого стека — ./stack sync"
      done
      ok "обслуживается доменов: $(printf '%s\n' "$served" | grep -c .)"
    fi
  fi

  step "Контейнеры"
  while IFS= read -r s; do
    local running total
    running="$(stack_running "$s")"
    total="$(stack_services "$s" 2>/dev/null | grep -c . || true)"
    if [ "$total" -eq 0 ]; then
      # Стек без своих контейнеров — на этой машине норма, а не находка: сайт
      # живёт на платформенных nginx и php-fpm, а docroot лежит в общем
      # $Platform_Vhosts_Dir. Отличаем от стека, у которого compose-файл есть, но
      # сервисов в нём не нашлось: вот это уже поломка разбора.
      if [ ! -f "$(stack_compose_file "$s")" ]; then
        ok "$s: своих контейнеров нет — живёт на платформенных nginx/php-fpm"
      else
        warn "$s: в compose-файле не нашлось сервисов"
      fi
    elif [ "$running" -eq 0 ]; then
      bad "$s: включён, но ни один контейнер не запущен"
    else
      ok "$s: $running/$total запущено"
    fi
  done < <(stacks_enabled 2>/dev/null)

  while IFS= read -r s; do
    stack_is_enabled "$s" && continue
    local left
    left="$(stack_containers "$s" | grep -c . || true)"
    [ "$left" -gt 0 ] && bad "$s: выключен, но остались контейнеры ($left) — watch-host.sh будет считать это аварией"
  done < <(stacks_available)

  # Контейнер с меткой проекта, чьего сервиса не объявляет НИ ОДИН стек, не
  # виден больше ничему: stack_containers ищет по именам сервисов из
  # compose-файлов, а у переименованного или удалённого сервиса такого имени
  # там нет. Остановленный, но с restart: unless-stopped, он при этом вечная
  # авария для watch-host.sh. Из докера его видно только как compose-orphan,
  # то есть в предупреждении к чужой команде.
  local known cname csvc orphans=0 seen=0
  known="$(stacks_known_services | sed '/^$/d' | sort -u)"
  while IFS=$'\t' read -r cname csvc; do
    [ -n "$cname" ] || continue
    seen=$((seen + 1))
    if [ -n "$csvc" ] && printf '%s\n' "$known" | grep -qxF "$csvc"; then continue; fi
    orphans=$((orphans + 1))
    bad "контейнер $cname не принадлежит ни одному стеку (сервис '${csvc:-без метки}') — docker rm -f $cname"
  done < <(project_containers)
  # Ноль контейнеров у проекта — это не «всё чисто», а «спросить не удалось»:
  # на живой машине их всегда больше нуля. Молчаливое [ok] здесь было бы ровно
  # тем отказом, ради которого весь этот блок и написан.
  if [ "$seen" -eq 0 ]; then
    warn "контейнеров проекта не видно — docker не отвечает? бесхозные не проверены"
  elif [ "$orphans" -eq 0 ]; then
    ok "бесхозных контейнеров проекта нет"
  fi

  # Объявленные юниты и установленные расходятся молча в обе стороны, и обе
  # стороны стоят одинаково дорого: у включённого стека задача не выполняется
  # вовсе, у выключенного — машина просыпается по таймеру мёртвого стека и
  # запускает скрипты по контейнерам, которых нет.
  #
  # Раскладку приводит в порядок systemd.sh; здесь только вопрос, нужен ли он.
  step "Юниты systemd"
  local unit uinst units_wrong=0
  while IFS= read -r s; do
    while IFS= read -r unit; do
      [ -n "$unit" ] || continue
      stack_units_installed "$s" | grep -qxF "$(basename "$unit")" && continue
      units_wrong=$((units_wrong + 1))
      bad "$s: юнит $(basename "$unit") объявлен, но не установлен — sudo ./platform/bin/systemd.sh"
    done < <(stack_units "$s")
  done < <(stacks_enabled 2>/dev/null)

  while IFS= read -r s; do
    stack_is_enabled "$s" && continue
    while IFS= read -r uinst; do
      [ -n "$uinst" ] || continue
      units_wrong=$((units_wrong + 1))
      bad "$s: выключен, но юнит $uinst установлен — машина будет просыпаться по нему; sudo ./platform/bin/systemd.sh"
    done < <(stack_units_installed "$s")
  done < <(stacks_available)

  [ "$units_wrong" -eq 0 ] && ok "юниты стеков соответствуют манифесту"

  # «Запущен» и «работает» — разные вещи: контейнер с мёртвым приложением
  # внутри выглядит в docker ps точно так же, как исправный.
  #
  # Два источника сигнала, и оба — объявление стека, а не список в этом файле.
  # Первый бесплатный: healthcheck самого docker'а, если он есть в compose.
  # Второй — stacks/<стек>/scripts/health.sh, для того, что docker выразить не
  # может: ответ приложения через nginx, свежесть данных, длина очереди.
  step "Здоровье стеков"
  local cid cname cstate healthy=0 nohc=0 hscript hrc hout without=""
  while IFS= read -r s; do
    while IFS= read -r cid; do
      [ -n "$cid" ] || continue
      cname="$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')"
      cstate="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$cid" 2>/dev/null || true)"
      case "$cstate" in
        healthy)   healthy=$((healthy + 1)) ;;
        unhealthy) bad "$s: контейнер $cname — unhealthy; docker logs $cname --tail 30" ;;
        starting)  warn "$s: контейнер $cname ещё стартует (healthcheck starting)" ;;
        *)         nohc=$((nohc + 1)) ;;
      esac
    done < <(stack_containers "$s")
  done < <(stacks_enabled 2>/dev/null)
  # Ноль контейнеров — это не «все здоровы», а «смотреть было не на что»:
  # о том, что стек не запущен, отдельной строкой говорит блок «Контейнеры».
  if [ $((healthy + nohc)) -gt 0 ]; then
    ok "docker healthcheck: здоровых $healthy, без healthcheck $nohc"
  fi

  while IFS= read -r s; do
    hscript="$(stack_health_script "$s")"
    if [ ! -f "$hscript" ]; then without="$without $s"; continue; fi
    if [ ! -x "$hscript" ]; then
      warn "$s: scripts/health.sh не исполняемый — chmod +x $hscript"
      continue
    fi
    # Код возврата берём через `|| hrc=$?`: под errexit обычное присваивание из
    # упавшей команды оборвало бы --check на первом же нездоровом стеке, не
    # напечатав ни его имени, ни причины.
    hrc=0
    hout="$(cd "$ROOT_DIR" && STACK_DIR="$(stack_dir "$s")" ROOT_DIR="$ROOT_DIR" \
            run_with_timeout "$HEALTH_TIMEOUT" "$hscript" 2>&1)" || hrc=$?
    case "$hrc" in
      0)   ok "$s: health.sh — стек отвечает" ;;
      124) bad "$s: health.sh не ответил за ${HEALTH_TIMEOUT} с" ;;
      *)   bad "$s: health.sh вернул $hrc — $(printf '%s' "$hout" | sed -n '1p')" ;;
    esac
  done < <(stacks_enabled 2>/dev/null)
  [ -n "$without" ] && printf '  [--]   своей проверки нет:%s (stacks/<стек>/scripts/health.sh)\n' "$without"

  # Сверка разбора yaml с самим compose. Список сервисов lib-stacks.sh получает
  # регуляркой, и молчаливое расхождение здесь означает, что disable не удалит
  # часть контейнеров стека.
  step "Разбор compose-файлов"
  # platform/compose/nginx.yaml подключаем и здесь: файлы стеков ссылаются на
  # объявленную в нём сеть shared_network, и в одиночку `config` на них падает
  # с «refers to undefined network». Сервисы самого корневого файла (nginx) из
  # сравнения вычитаем — lib-stacks.sh исключает их намеренно.
  local base_svc cfg_args cfg_files dep dsvc ef pf
  base_svc="$(platform_services)"
  while IFS= read -r s; do
    # Стек без своих контейнеров сверять не с чем: compose-файла у него нет.
    [ -f "$(stack_compose_file "$s")" ] || continue
    awk_svc="$(stack_services "$s" 2>/dev/null | sort | tr '\n' ' ')"
    # Файлы стеков-зависимостей тоже нужны: `depends_on` ссылается на сервис
    # чужого стека (mysqld из стека mysql), и в одиночку `config` падает
    # с «depends on undefined service».
    #
    # Пути берём из тех же helper'ов, что и docker-compose.sh, а не собираем
    # из имени стека: собранный строчно путь расходится с раскладкой молча —
    # `config` падает на каждом стеке, и проверка перестаёт что-либо сверять,
    # выглядя при этом рабочей.
    cfg_args=(--project-directory "$ROOT_DIR" --env-file .env)
    # Платформенные файлы — списком ИЗ КАТАЛОГА, а не перечислением. Здесь
    # стоял `-f platform/compose/php-fpm.yaml`, оставшийся с тех пор, когда
    # php-fpm был платформенным сервисом. Файла нет, `docker compose` падает на
    # несуществующем -f, а 2>/dev/null ниже это съедает: cfg_svc пуст, и для
    # КАЖДОГО стека печаталось «config не отработал». Проверка, существующая
    # чтобы поймать расхождение разбора yaml, была мертва на всех машинах.
    cfg_files=()
    for pf in "$ROOT_DIR"/platform/compose/*.yaml; do
      [ -f "$pf" ] || continue
      case "$pf" in *.generated.yaml) continue ;; esac
      cfg_files+=(-f "${pf#"$ROOT_DIR"/}")
    done
    for dep in "$s" $(stack_requires "$s"); do
      ef="$(stack_env_file "$dep")"
      [ -f "$ef" ] && cfg_args+=(--env-file "$ef")
      [ -f "$(stack_compose_file "$dep")" ] && cfg_files+=(-f "$(stack_compose_file "$dep")")
    done
    cfg_svc="$(cd "$ROOT_DIR" && docker compose "${cfg_args[@]}" "${cfg_files[@]}" config --services 2>/dev/null \
               | grep -vxF "$base_svc" | sort | tr '\n' ' ' || true)"
    # Из вывода вычитаем сервисы стеков-зависимостей: сверяем список ЭТОГО стека.
    #
    # `|| true` на обоих grep'ах: когда `config` не отработал, cfg_svc пуст,
    # grep по пустому входу возвращает 1, и под `set -e` verb_check умирал
    # ровно здесь — не напечатав ни строки и не дойдя ни до статики, ни до
    # «Итога». То есть отказ, для которого строкой ниже написан warn, гасил
    # сам этот warn.
    for dep in $(stack_requires "$s"); do
      while IFS= read -r dsvc; do
        [ -n "$dsvc" ] && cfg_svc="$(printf '%s' "$cfg_svc" | tr ' ' '\n' | grep -vx "$dsvc" | tr '\n' ' ' || true)"
      done < <(stack_services "$dep" 2>/dev/null)
    done
    cfg_svc="$(printf '%s' "$cfg_svc" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ' || true)"
    if [ -z "$cfg_svc" ]; then
      warn "$s: docker compose config не отработал — сверить список сервисов не с чем"
    elif [ "$awk_svc" = "$cfg_svc" ]; then
      ok "$s: список сервисов совпадает с docker compose"
    else
      bad "$s: разбор yaml даёт '$awk_svc', а docker compose — '$cfg_svc'"
    fi
  done < <(stacks_enabled 2>/dev/null)

  step "Статика: что nginx смонтировал на самом деле"
  # Проверяем РЕЗУЛЬТАТ, а не формулу: сверять переменные поимённо значило бы
  # знать про конкретный стек, а отказ выглядит одинаково для любого —
  # переменная не задана или задана не туда, compose подставляет дефолт
  # ./vhosts, и домен отдаёт 404 из каталога, которого никто не имел в виду.
  if ! nginx_running; then
    warn "контейнер nginx не запущен — смонтированную статику не проверить"
  else
    local mounts; mounts=$(docker inspect nginx \
      --format '{{range .Mounts}}{{.Destination}}|{{.Source}}{{"\n"}}{{end}}' 2>/dev/null || true)
    local declared=0
    while IFS= read -r s; do
      for pair in $(stack_conf_get "$s" Static); do
        declared=$((declared + 1))
        local domain src
        domain="${pair%%:*}"
        src=$(printf '%s\n' "$mounts" | awk -F'|' -v d="/$domain" '$1 ~ d"$" { print $2; exit }')
        if [ -z "$src" ]; then
          bad "$s: статика для $domain не смонтирована — ./stack sync и up -d"
        elif [ ! -d "$src" ]; then
          bad "$s: статика для $domain смонтирована из '$src', которого нет — $domain отдаст 404"
        else
          case "$src" in
            */vhosts)
              warn "$s: статика для $domain смонтирована из '$src' — это дефолт-заглушка, а не каталог стека; проверьте переменную из Static= в корневом .env" ;;
            *) ok "$s: статика для $domain — $src" ;;
          esac
        fi
      done
    done < <(stacks_available)
    [ "$declared" -eq 0 ] && ok "ни один стек не объявляет Static — проверять нечего"
  fi

  step "Итог"
  echo "  проблем: $PROBLEMS, предупреждений: $WARNINGS"
  [ "$PROBLEMS" -gt 0 ] && exit 1
  exit 0
}

# ------------------------------------------------------------------ main

VERB=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=1 ;;
    --no-start) NO_START=1 ;;
    --no-units) NO_UNITS=1 ;;
    --check)    VERB="check" ;;
    -h|--help)  usage 0 ;;
    -*)         die "неизвестный флаг: $1" ;;
    *)          if [ -z "$VERB" ]; then VERB="$1"; else ARGS+=("$1"); fi ;;
  esac
  shift
done

case "${VERB:-list}" in
  list)    verb_list ;;
  check)   verb_check ;;
  sync)    verb_sync ;;
  enable)  [ ${#ARGS[@]} -gt 0 ] || die "укажите стек: $0 enable <стек>..."; verb_enable "${ARGS[@]}" ;;
  disable) [ ${#ARGS[@]} -gt 0 ] || die "укажите стек: $0 disable <стек>..."; verb_disable "${ARGS[@]}" ;;
  purge)   [ ${#ARGS[@]} -eq 1 ] || die "purge принимает РОВНО один стек: $0 purge <стек>"; verb_purge "${ARGS[0]}" ;;
  *)       die "неизвестная команда: '$VERB' (list|enable|disable|purge|sync|--check)" ;;
esac
