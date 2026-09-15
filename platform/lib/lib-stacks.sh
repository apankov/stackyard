# shellcheck shell=bash
# Состав стеков девбокса и то, какие из них включены. Подключается через
# `source`, самостоятельно не запускается.
#
# Источник правды один — Enabled_Stacks в .env-stacks, всё остальное выводится
# отсюда: набор compose-файлов, include'ы vhost'ов, юниты, домены. Второй
# список «какие стеки включены» где бы то ни было означает разъезд между
# compose и nginx, то есть `host not found in upstream` и краш-луп nginx,
# уносящий ВСЕ vhost'ы (CLAUDE.md §3.1).
#
# Ни от чего не зависит: манифест читается построчным grep'ом, поэтому файл
# подключается и из docker-compose.sh, который lib-env.sh не грузит.

# Межстековые зависимости: те стеки, без которых этот не работает.
#
# Это не косметика, и для этой машины особенно. PHP-сайт не имеет своих
# контейнеров вовсе: он живёт на платформенном php-fpm и ходит в общий mysqld
# по имени. Без Requires="php mysql" такой стек включается «успешно» и отдаёт
# 502 или «Access denied» — то есть отказ переезжает из момента включения в
# рантайм, где его ловит уже посетитель.
#
# Объявляет это сам стек в stack.conf: список внутри библиотеки означал бы, что
# стек с зависимостью не добавить, не правя её.
stack_requires() { stack_conf_get "$1" Requires; }

# ------------------------------------------------------------------ пути

stacks_root() {
  # ROOT_DIR задаёт вызывающий скрипт; здесь только страховка.
  printf '%s' "${ROOT_DIR:?ROOT_DIR не задан вызывающим скриптом}"
}

# Корни, в которых ищутся стеки, в порядке приоритета.
#
# Их два, и это весь механизм «копировать или подключать»:
#
#   stacks/          — стеки ЭТОЙ машины. Правятся свободно.
#   profile/stacks/  — библиотека переиспользуемых стеков, приехавшая вместе с
#                      профилем. Обновляется целиком, вместе с ним.
#
# Машинный корень идёт первым, поэтому стек, скопированный из профиля в
# stacks/, перекрывает профильный. Это и есть «отцепиться»: копия становится
# машинной, обновления профиля её больше не касаются, и видно это по одному
# `ls stacks/`, а не по записи в конфиге.
#
# Обратный порядок означал бы, что профиль молча перебивает машинную правку —
# худший исход: человек правит файл, который не читают.
stack_roots() {
  printf '%s/stacks\n' "$(stacks_root)"
  [ -d "$(stacks_root)/profile/stacks" ] && printf '%s/profile/stacks\n' "$(stacks_root)"
  return 0
}

# Каталог стека: первый корень, где лежит его stack.conf.
#
# Именно stack.conf, а не просто каталог. Разница не теоретическая: у ЛЮБОГО
# включённого стека, в том числе профильного, машина заводит
# stacks/<стек>/.env — секреты принадлежат машине. Считай мы такой каталог
# объявлением, профильный стек оказался бы перекрыт каталогом, в котором
# ничего, кроме .env, нет: compose-файл не нашёлся бы, а `stack.sh list`
# бодро докладывал бы «ок».
#
# Отсюда правило: объявляет стек тот каталог, где лежит stack.conf.
# Скопировать стек из профиля — значит скопировать его целиком, вместе с
# декларацией; половина копии стеком не становится.
stack_dir() {
  local r
  while IFS= read -r r; do
    [ -f "$r/$1/stack.conf" ] && { printf '%s/%s' "$r" "$1"; return 0; }
  done < <(stack_roots)
  printf '%s/stacks/%s' "$(stacks_root)" "$1"
}

stack_compose_file() { printf '%s/compose.yaml' "$(stack_dir "$1")"; }
stack_vhost_dir()    { printf '%s/nginx' "$(stack_dir "$1")"; }
stack_conf_file()    { printf '%s/stack.conf' "$(stack_dir "$1")"; }

# .env стека — ВСЕГДА в машинном корне, даже у профильного стека.
#
# Секреты принадлежат машине, а не профилю: профиль приезжает вендорингом и
# обновляется целиком, и положить пароль внутрь него значило бы, что следующее
# обновление его затрёт, а git профиля его увидит.
stack_env_file()     { printf '%s/stacks/%s/.env' "$(stacks_root)" "$1"; }

# Каталог стеков ВНУТРИ контейнера nginx. Значение обязано совпадать с целью
# монтирования $Platform_Deploy_Dir/stacks в platform/compose/nginx.yaml:
# генерируемый 00-enabled.conf читает nginx, а не хост.
STACKS_DIR_IN_CONTAINER="/etc/nginx/stacks"
STACKS_PROFILE_DIR_IN_CONTAINER="/etc/nginx/profile-stacks"

# Каталог стека ВНУТРИ контейнера nginx. Корня два, и include обязан указывать
# в тот же, где стек лежит на самом деле: иначе после копирования стека из
# профиля в машинный stacks/ nginx продолжал бы читать профильную копию.
stack_dir_in_container() {
  case "$(stack_dir "$1")" in
    "$(stacks_root)/profile/stacks/"*) printf '%s/%s' "$STACKS_PROFILE_DIR_IN_CONTAINER" "$1" ;;
    *)                                 printf '%s/%s' "$STACKS_DIR_IN_CONTAINER" "$1" ;;
  esac
}

# Сгенерированный файл с include'ами включённых стеков. Лежит в conf.d рядом с
# vhost'ами платформы; префикс 00- задаёт предсказуемый порядок чтения, но на
# выбор сервера по умолчанию не влияет: default_server проставлен явно в
# default.conf.
stacks_include_file() { printf '%s/state/nginx-vhosts/00-enabled.conf' "$(stacks_root)"; }

# Генерируемый файл с томами статики стеков. Тоже в git не лежит: описывает
# конкретную машину и выводится из Static= в stacks/*/stack.conf.
stacks_static_file()  { printf '%s/state/nginx-static.generated.yaml' "$(stacks_root)"; }

# ------------------------------------------------------- поставщик БД
#
# Движок НЕ знает, какая на машине СУБД. Он знает только роль: некий включённый
# стек объявляет себя поставщиком общей базы, и тогда остальные стеки могут
# заказывать у него базу и пользователя.
#
# Раньше здесь стояли имена — `mysql`, `Mysql_DB`, контейнер `mysql-initializer`.
# Из-за этого машина на Postgres требовала форка движка: тот же код с заменой
# семи слов. Имя в движке там, где смысл — роль, и есть механизм расхождения
# платформы между машинами.
#
# Стек-поставщик объявляет себя в своём stack.conf:
#
#   Provides_DB="Mysql"                 префикс ключей, которые он понимает
#   DB_Init_Service="mysql-initializer" одноразовый контейнер, заводящий базы
#
# Потребитель пишет ключи с этим префиксом: Mysql_DB, Mysql_User, Mysql_Password
# (и что ещё поставщик понимает — Mysql_Grants, Mysql_Dump). Движку эти ключи
# непрозрачны: он их только собирает и отдаёт поставщику.

# Имя включённого стека-поставщика, либо пусто.
#
# Двух поставщиков на машине быть не может: ключи потребителей различаются
# префиксом, а не адресатом, и второй поставщик с тем же префиксом тихо
# перехватывал бы чужие декларации. Проверяет check_db_providers_unique.
stacks_db_provider() {
  local s
  while IFS= read -r s; do
    [ -n "$(stack_conf_get "$s" Provides_DB)" ] && { printf '%s' "$s"; return 0; }
  done < <(stacks_enabled 2>/dev/null)
  return 0
}

# Префикс ключей поставщика (Mysql, Postgres, ...).
stacks_db_prefix() {
  local p; p="$(stacks_db_provider)"
  [ -n "$p" ] && stack_conf_get "$p" Provides_DB
  return 0
}

# Имя одноразового контейнера, заводящего базы. Нужно `--check`: у него нет
# restart: always, поэтому его падение снаружи выглядит просто как `exited`.
stacks_db_init_service() {
  local p; p="$(stacks_db_provider)"
  [ -n "$p" ] && stack_conf_get "$p" DB_Init_Service
  return 0
}

# Генерируемый список баз. Лежит ВНУТРИ каталога поставщика, потому что оттуда
# его читает инициализатор, — но пишет его платформа, из деклараций всех
# включённых стеков. Ровно так же platform/nginx-vhosts/00-enabled.conf лежит
# рядом с nginx: место определяет потребитель, а не автор.
#
# Профильный поставщик — исключение из «генерируемое лежит у потребителя»:
# писать внутрь profile/ нельзя, его затрёт следующее обновление профиля.
# Поэтому файл всегда в машинном корне, под именем стека-поставщика.
#
# СОДЕРЖИТ ПАРОЛИ: chmod 600, в git не лежит.
stacks_databases_file() {
  local p; p="$(stacks_db_provider)"
  [ -n "$p" ] || return 0
  printf '%s/state/%s/databases.yaml' "$(stacks_root)" "$p"
}

# Два поставщика сразу — это спор за префикс и почти наверняка недосмотр при
# включении стека.
check_db_providers_unique() {
  local s found=""
  while IFS= read -r s; do
    [ -n "$(stack_conf_get "$s" Provides_DB)" ] || continue
    [ -n "$found" ] && printf 'поставщиков общей БД включено больше одного: %s и %s\n' "$found" "$s"
    found="$s"
  done < <(stacks_enabled 2>/dev/null)
  return 0
}

# ------------------------------------------------------------- stack.conf

# stack_conf_get <стек> <ключ> [<по умолчанию>]
#
# Разбор построчным grep'ом, БЕЗ lib-env.sh и без разворачивания ${...}.
# Причины две, и обе важные:
#
#   1. lib-stacks.sh подключает docker-compose.sh, который lib-env.sh не грузит
#      (см. заголовок файла). Зависимость появиться здесь не должна.
#   2. stack.conf обязан читаться у стека, который ВЫКЛЮЧЕН и у которого .env
#      на этой машине нет вовсе. Разворачивать в такой ситуации нечем, а
#      подставить пустую строку — худший исход: пустой host-путь в томе
#      означает каталог-пустышку от root и молчаливые 404.
#
# Значения с ${...} — это только Static — уходят в генерируемый compose-файл
# дословно, и разворачивает их сам compose из корневого .env. Ключи Backup_*
# читает backup.sh: он работает лишь по включённым стекам, грузит lib-env.sh и
# разворачивает подстановки штатно.
stack_conf_get() {
  local s="$1" key="$2" default="${3-}" file val=""
  file="$(stack_conf_file "$s")"
  if [ -f "$file" ]; then
    val=$(grep -E "^[[:space:]]*${key}=" "$file" | tail -n 1 | cut -d '=' -f2- | tr -d '"'"'" || true)
  fi
  if [ -z "$val" ]; then printf '%s' "$default"; else printf '%s' "$val"; fi
}

# ------------------------------------------------------- список стеков

# Все стеки — это каталоги в stacks/. Имя каталога и есть имя стека, вычитать
# из списка нечего: в stacks/ по определению лежат только стеки.
stacks_available() {
  local r d
  while IFS= read -r r; do
    for d in "$r"/*/; do
      d="${d%/}"
      # stack.conf, а не просто каталог — см. stack_dir. Каталог с одним .env
      # стеком не является и в списке появляться не должен.
      [ -f "$d/stack.conf" ] || continue
      printf '%s\n' "${d##*/}"
    done
  done < <(stack_roots) | sort -u
}

stack_exists() {
  local s
  while IFS= read -r s; do [ "$s" = "$1" ] && return 0; done < <(stacks_available)
  return 1
}

# Включённые стеки — из Enabled_Stacks в .env-stacks, в порядке из файла.
#
# Отсутствующий .env-stacks НЕ является отказом: свежий `git pull` на сервере
# не должен ронять все compose-команды на машине — это ровно тот класс
# поломок, который здесь лечится. Поэтому предупреждение в stderr и откат к
# «все стеки, для которых есть все файлы».
stacks_enabled() {
  local manifest="$(stacks_root)/.env-stacks" raw s

  # Переопределение из stack.sh: он уже знает, каким станет манифест, и под
  # --dry-run файл не пишет. Без этого dry-run сравнивал бы include'ы со СТАРЫМ
  # составом и бодро докладывал «уже соответствуют» — то есть врал ровно в том
  # режиме, который существует, чтобы не врать.
  if [ -n "${STACKS_ENABLED_OVERRIDE+x}" ]; then
    for s in $STACKS_ENABLED_OVERRIDE; do printf '%s\n' "$s"; done
    return 0
  fi

  if [ -f "$manifest" ]; then
    raw=$(grep -E '^[[:space:]]*Enabled_Stacks=' "$manifest" | tail -n 1 | cut -d '=' -f2- | tr -d '"'"'" || true)
    for s in $raw; do
      if stack_exists "$s"; then
        printf '%s\n' "$s"
      else
        echo "Предупреждение: в .env-stacks указан стек '$s', но каталога stacks/$s нет — пропускаю" >&2
      fi
    done
    return 0
  fi

  echo "Предупреждение: нет .env-stacks — считаю включёнными все стеки с полным набором файлов." >&2
  echo "  Заведите манифест: cp .env-stacks.example .env-stacks && ./scripts/stack.sh sync" >&2
  while IFS= read -r s; do
    [ -z "$(stack_missing_files "$s")" ] && printf '%s\n' "$s"
  done < <(stacks_available)
}

stack_is_enabled() {
  local s
  while IFS= read -r s; do [ "$s" = "$1" ] && return 0; done < <(stacks_enabled 2>/dev/null)
  return 1
}

# Включённые стеки, которым нужен указанный стек.
stack_dependents() {
  local target="$1" s req
  while IFS= read -r s; do
    for req in $(stack_requires "$s"); do
      [ "$req" = "$target" ] && printf '%s\n' "$s"
    done
  done < <(stacks_enabled 2>/dev/null)
}

# Чего не хватает стеку, чтобы его можно было включить. Пустой вывод — всё есть.
stack_missing_files() {
  local s="$1"
  # compose.yaml обязателен у стека, у которого есть СВОИ контейнеры.
  #
  # Стек без контейнеров — не редкость: статический сайт живёт на платформенных
  # nginx и php-fpm, а прокси-стек только описывает vhost к чужому приложению.
  # Но отсутствие compose.yaml само по себе объявлением НЕ считается: забытый
  # файл у обычного стека выглядел бы точно так же и давал бы рабочий конфиг, в
  # котором ничего не запускается.
  #
  # Поэтому объявление явное — Containers="no" в stack.conf.
  if [ "$(stack_conf_get "$s" Containers yes)" != "no" ] && [ ! -f "$(stack_compose_file "$s")" ]; then
    printf 'stacks/%s/compose.yaml (либо Containers="no" в stack.conf, если своих контейнеров нет)\n' "$s"
  fi
  # .env стека обязателен только там, где есть образец: статические сайты и
  # redis обходятся корневым .env, и требовать от них env-файл значило бы
  # выдумать поломку.
  # Образец ищем РЯДОМ СО СТЕКОМ, а сам .env — в машинном корне. Для машинного
  # стека это один каталог, для профильного — разные, и проверять оба места
  # одинаково нельзя: у профильного стека образец лежит в profile/, и поиск
  # образца по машинному пути не нашёл бы его никогда. Стек mysql тогда
  # считался бы укомплектованным без пароля root, а mysqld не поднялся бы —
  # с отказом интерполяции из середины compose вместо внятной строки здесь.
  if [ -f "$(stack_dir "$s")/.env.example" ] && [ ! -f "$(stack_env_file "$s")" ]; then
    printf 'stacks/%s/.env\n' "$s"
  fi
}

# --------------------------------------------------------------- проверки
#
# Каждая печатает по строке на найденную проблему и молчит, когда её нет. Так
# они одинаково годятся и для selftest.sh, и для stack.sh --check, и ни одна не
# решает сама, что делать с находкой.

# Один домен у двух стеков — это гарантированный отказ nginx на старте
# ("conflicting server name") и спор двух конфигов getssl за один сертификат.
check_domains_unique() {
  local s d a
  while IFS= read -r s; do
    for d in $(stack_conf_get "$s" Domains); do
      printf '%s\t%s\n' "$(domain_primary "$d")" "$s"
      for a in $(domain_sans "$d"); do printf '%s\t%s\n' "$a" "$s"; done
    done
  done < <(stacks_available) | sort | awk -F'\t' '
    { if ($1 == prev) print "домен " $1 " объявлен и в " prevs ", и в " $2; prev = $1; prevs = $2 }'
}

# Домен в stack.conf без server_name во vhost'ах стека означает сертификат,
# который выпускается и никому не служит; обратное — vhost, работающий до тех
# пор, пока кто-нибудь не заметит, что сертификата у него нет.
check_domains_match() {
  local s="$1" declared served d
  declared=$(for d in $(stack_conf_get "$s" Domains); do
               printf '%s\n' "$(domain_primary "$d")"
               for a in $(domain_sans "$d"); do printf '%s\n' "$a"; done
             done | sed '/^$/d' | sort -u)
  # `|| true` по той же причине, что и в stacks_upstreams: у стека, объявившего
  # Domains и не заведшего nginx/, grep возвращает ненулевой код, и под `set -e`
  # из stack.sh функция умирала ровно здесь — не напечатав той единственной
  # находки, ради которой её и зовут («домен объявлен, vhost'а нет»).
  served=$(grep -rhE '^[[:space:]]*server_name[[:space:]]' "$(stack_vhost_dir "$s")" 2>/dev/null \
           | awk '{for (i = 2; i <= NF; i++) print $i}' | tr -d ';' | sed '/^$/d' | sort -u || true)
  for d in $(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$served")); do
    printf 'стек %s: домен %s объявлен в stack.conf, но ни один vhost его не обслуживает\n' "$s" "$d"
  done
  for d in $(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$served")); do
    printf 'стек %s: vhost обслуживает %s, но домена нет в stack.conf — сертификат ему не выпускается\n' "$s" "$d"
  done
}

# Относительный host-путь резолвится от каталога проекта, а не от файла стека.
# Каталог проекта задан явно (--project-directory в docker-compose.sh), но
# полагаться на него из файлов стеков не следует: путь становится верным по
# совпадению, а не по объявлению.
#
# Именованные тома (`- somevolume:/data`) двоеточие тоже содержат, но их
# host-часть путём не выглядит и сюда не попадает: проверяются только
# кандидаты, начинающиеся с точки.
check_paths_absolute() {
  local s="$1"
  awk -v s="$s" '
    # Выход из блока: первая непустая строка с отступом не глубже самого
    # volumes:. Комментарии и пустые строки внутри блока его не закрывают.
    in_vol && !/^[[:space:]]*-[[:space:]]/ {
      match($0, /^[[:space:]]*/)
      if ($0 ~ /[^[:space:]]/ && RLENGTH <= vol_indent) in_vol = 0
    }
    /^[[:space:]]+volumes:[[:space:]]*(#.*)?$/ {
      match($0, /^[[:space:]]*/); vol_indent = RLENGTH; in_vol = 1; next
    }
    in_vol && match($0, /^[[:space:]]*-[[:space:]]+/) {
      v = substr($0, RLENGTH + 1)
      sub(/[[:space:]]*(#.*)?$/, "", v)
      gsub(/^["'"'"']|["'"'"']$/, "", v)
      if (v ~ /^\.{1,2}\//) {
        print "стек " s ": относительный host-путь в томе: " v
      } else if (v ~ /^\// && v !~ /\$/) {
        print "стек " s ": захардкоженный host-путь в томе (нужна переменная): " v
      }
    }
  ' "$(stack_compose_file "$s")" 2>/dev/null
}

# /etc/systemd/system плоский. Без префикса два стека подерутся за имя, и
# победит тот, чьи юниты поставили последними.
check_unit_names() {
  local s="$1" u n
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    n=$(basename "$u")
    case "$n" in
      devbox-"$s"-*) ;;
      *) printf 'стек %s: юнит %s без префикса devbox-%s-\n' "$s" "$n" "$s" ;;
    esac
  done < <(stack_units "$s")
}

# CLAUDE.md §5: задача, переставшая выполняться, выглядит ровно как задача,
# которой нечего делать. Отличить одно от другого может только независимая
# проверка результата, поэтому таймер без неё — неполная задача.
check_timer_has_check() {
  local s="$1" u n base
  while IFS= read -r u; do
    case "$u" in *.timer) ;; *) continue ;; esac
    n=$(basename "$u" .timer)
    base="${n#devbox-"$s"-}"
    [ -f "$(stack_dir "$s")/scripts/check-$base.sh" ] && continue
    [ -f "$(stack_dir "$s")/systemd/$n-check.timer" ] && continue
    printf 'стек %s: у таймера %s нет проверки (scripts/check-%s.sh или %s-check.timer)\n' \
      "$s" "$n" "$base" "$n"
  done < <(stack_units "$s")
}

# Сервисы платформы: всё, что объявлено в platform/compose/*.yaml, кроме
# генерируемого файла статики (он домешивает том в уже объявленный nginx и
# новых сервисов не заводит).
#
# Их два — nginx и php-fpm, и второй здесь не для симметрии. PHP-сайты ходят в
# него через `fastcgi_pass php-fpm:9000`, а этот адрес nginx резолвит при
# ЧТЕНИИ конфига, ровно как proxy_pass: нет контейнера — нет старта nginx —
# `restart: always` превращает это в краш-луп, уносящий все сайты машины.
# Поэтому php-fpm подчиняется тем же правилам, что и nginx: спека постоянна,
# стеки в неё ничего не домешивают.
platform_services() {
  local f
  for f in "$(stacks_root)"/platform/compose/*.yaml; do
    [ -f "$f" ] || continue
    case "$f" in *.generated.yaml) continue ;; esac
    _stacks_yaml_keys "$f" services
  done
}

# Стек, домешивающий что-либо в сервис платформы, делает её спеку зависящей от
# набора включённых стеков — то есть возвращает ровно ту поломку, ради которой
# существует генератор статики.
check_no_base_service_merge() {
  local s="$1" base svc
  base=$(platform_services)
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    # `if`, а не `&&`: список с `&&` в конце тела цикла отдаёт наружу код
    # последнего grep'а, то есть функция «падает» ровно тогда, когда претензий
    # НЕТ. Само по себе это безобидно, пока её зовут через подстановку
    # процесса, но первый же вызов вида `check_... || die` сработал бы наоборот.
    if printf '%s\n' "$base" | grep -qx -- "$svc"; then
      printf 'стек %s: домешивает в общий сервис %s — объявите статику через Static= в stack.conf\n' "$s" "$svc"
    fi
  done < <(_stacks_yaml_keys "$(stack_compose_file "$s")" services)
}

# Цикл в Requires означает, что enable и disable зациклятся на разрешении
# зависимостей и не завершатся никогда.
check_requires_cycle() {
  local s="$1" seen=" $1 " queue next r depth=0
  queue=$(stack_requires "$s")
  while [ -n "$queue" ] && [ "$depth" -lt 20 ]; do
    next=""
    for r in $queue; do
      case "$seen" in
        *" $r "*) printf 'цикл в Requires: %s → ... → %s\n' "$s" "$r"; return 0 ;;
      esac
      seen="$seen$r "
      next="$next $(stack_requires "$r")"
    done
    queue="$next"
    depth=$((depth + 1))
  done
}

# Upstream'ы, на которые ссылаются vhost'ы включённых стеков.
#
# Каталога nginx/ у стека может не быть законно (mysql, redis), и находок в нём
# может не быть тоже — но `grep` в обоих случаях возвращает ненулевой код, а
# stack.sh работает под `set -e`. Подоболочка цикла умирала на ПЕРВОМ таком
# стеке, и функция отдавала пусто: в манифесте первым идёт pg, поэтому
# проверка upstream'ов не проверяла ничего и никогда — молча, с пустым блоком
# вместо строк. Отсюда и `[ -d ]`, и `|| true`: одного мало, они закрывают
# разные половины (нет каталога / нет совпадений).
stacks_upstreams() {
  local s dir
  while IFS= read -r s; do
    dir="$(stack_vhost_dir "$s")"
    [ -d "$dir" ] || continue
    # fastcgi_pass наравне с proxy_pass, и это не мелочь: PHP-сайтов на этой
    # машине большинство, а `fastcgi_pass php-fpm:9000` nginx резолвит при
    # чтении конфига ровно так же. Опущенный php-fpm при пересоздании nginx
    # уносит ВСЕ сайты, включая статические, которым PHP не нужен вовсе.
    grep -rhE '^[[:space:]]*(proxy_pass|fastcgi_pass)[[:space:]]' "$dir" 2>/dev/null || true
  done < <(stacks_enabled 2>/dev/null) \
    | sed -E 's|^[[:space:]]*fastcgi_pass[[:space:]]+|//|' \
    | sed -E 's|.*//([^/:;]+).*|\1|' | sed '/^$/d' \
    | grep -vxF 'host.docker.internal' \
    | sort -u
  return 0
}

# host.docker.internal исключён намеренно: это не контейнер, а алиас самого
# хоста, который даёт `extra_hosts: host-gateway`. Проверка ищет upstream среди
# запущенных контейнеров, и для него она всегда докладывала бы «не запущен» —
# то есть машина с апстримом вне docker-сети имела бы вечный красный блок.
# Вечно красная проверка перестаёт читаться целиком, вместе с настоящими
# находками.
#
# Живо ли то, что слушает на хосте, отсюда не видно вовсе. Это забота стека:
# см. scripts/health.sh.

# ------------------------------------------------------- реестры образов
#
# Смысл: стек запускается от DIGEST'а, а
# не от подвижного тега. `:master` означает, что `up -d` берёт то, что уже лежит
# локально, молча расходится с реестром, и откатиться некуда — предыдущего тега
# не существует.


# Согласованность того, чем стек тянет образ, с тем, что он объявляет.
#
# Вопрос ровно один: как стек выбирает версию образа. Digest (`repo@${ПЕРЕМЕННАЯ}`)
# отвечает «что сейчас запущено» и хранится в .env стека, `Image_Tag=` в
# stack.conf — «за каким подвижным тегом следим», и это работа scripts/registry.sh.
# Половина этой пары бесполезна: тег без digest'а некуда записать, digest без
# тега неоткуда обновить. Разъезжается такое молча — pin просто перестаёт
# делать то, зачем его зовут.
check_image_decl() {
  local s="$1" img tag has_reg=0 digest=0
  tag="$(stack_image_tag "$s")"
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    has_reg=1
    case "$img" in *@\$\{*) digest=1 ;; esac
  done < <(stack_registry_images "$s")

  if [ -n "$tag" ] && [ "$has_reg" -eq 0 ]; then
    printf 'стек %s: объявлен Image_Tag=%s, но ни один образ не тянется из внешнего реестра\n' "$s" "$tag"
  fi
  if [ -n "$tag" ] && [ "$has_reg" -eq 1 ] && [ "$digest" -eq 0 ]; then
    printf 'стек %s: Image_Tag=%s объявлен, а образ задан не через digest — пинить нечего\n' "$s" "$tag"
  fi
  if [ -z "$tag" ] && [ "$digest" -eq 1 ]; then
    printf 'стек %s: образ пинится digest'"'"'ом, но Image_Tag= не объявлен — обновлять его нечем\n' "$s"
  fi
}


# --------------------------------------------------------------- реестры

# Хост реестра у ссылки на образ, либо пусто для Docker Hub.
#
# Правило докера, а не эвристика: реестром считается первый сегмент пути, если
# в нём есть точка или двоеточие (либо это localhost). Без этого `team/app`
# (образ Hub'а) и `реестр.example/app` неразличимы.
image_registry() {
  local v="${1%%/*}"
  [ "$v" = "$1" ] && return 0
  case "$v" in
    localhost|localhost:*|*.*|*:*) printf '%s' "$v" ;;
  esac
}


# Ссылки на образы стека, лежащие во ВНЕШНЕМ реестре (не Docker Hub).
#
# Значения с ${...} внутри возвращаются дословно: подстановку разворачивает
# compose, а имя хоста и репозитория стоит в compose-файле литералом именно
# затем, чтобы его можно было прочитать отсюда — у выключенного стека .env на
# машине нет вовсе (см. stack_conf_get).
stack_registry_images() {
  local img
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    if [ -n "$(image_registry "$img")" ]; then printf '%s\n' "$img"; fi
  done < <(stack_images "$1")
}


# stacks_registries [<стек>...]
#
# Хосты внешних реестров, которые упоминают перечисленные стеки; без аргументов
# — все стеки в stacks/. Логин нужен только тем реестрам, откуда сейчас могут
# тянуть, поэтому scripts/registry.sh передаёт сюда включённые; вопрос «ходит
# ли эта машина в реестры вообще» задаётся без аргументов.
stacks_registries() {
  local s img
  { if [ $# -gt 0 ]; then printf '%s\n' "$@"; else stacks_available; fi; } | {
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      while IFS= read -r img; do
        if [ -n "$img" ]; then image_registry "$img"; printf '\n'; fi
      done < <(stack_registry_images "$s")
    done
  } | sed '/^$/d' | sort -u
}


# Подвижный тег, за которым стек следит в реестре (`Image_Tag=` в stack.conf).
#
# Нужен только scripts/registry.sh: он резолвит этот тег в digest, а запускается
# стек всегда от digest'а. Тег и digest — разные вопросы и живут врозь: тег
# отвечает «за чем следим» и одинаков на всех машинах, поэтому лежит в
# декларации; digest отвечает «что сейчас запущено», меняется каждым деплоем и
# поэтому лежит в .env стека, рядом с остальным серверным состоянием.
stack_image_tag() { stack_conf_get "$1" Image_Tag; }

# ------------------------------------------------------------------ nginx

# Строки include для включённых стеков, у которых есть непустой каталог
# vhost'ов.
#
# Порядок — по наименьшему имени файла внутри каталога, а не по алфавиту имён
# стеков. Причина конкретная: в default.conf нет `default_server`, поэтому
# сервером по умолчанию nginx считает ПЕРВЫЙ прочитанный vhost (сегодня это
# 01-webhooks). Алфавит по стекам поменял бы это молча.
stacks_include_lines() {
  local s dir first
  while IFS= read -r s; do
    dir="$(stack_vhost_dir "$s")"
    [ -d "$dir" ] || continue
    first=$(ls -1 "$dir"/*.conf 2>/dev/null | sed 's:.*/::' | sort | head -n 1)
    [ -n "$first" ] || continue
    printf '%s\t%s\n' "$first" "$s"
  done < <(stacks_enabled) | sort | while IFS=$'\t' read -r _ s; do
    printf 'include %s/%s/nginx/*.conf;\n' "$STACKS_DIR_IN_CONTAINER" "$s"
  done
}


# --------------------------------------------------------------- systemd

# Файлы юнитов стека. Пусто, если каталога systemd/ нет — наличие каталога и
# есть объявление, отдельного ключа в stack.conf для этого не нужно.
stack_units() {
  local f
  for f in "$(stack_dir "$1")"/systemd/*.service "$(stack_dir "$1")"/systemd/*.timer; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done
}

# Текст юнита с подставленными плейсхолдерами.
#
# Юниты systemd не умеют переменных вовсе — ни своих, ни окружения на этапе
# разбора. Поэтому подстановка делается здесь, при установке, и все пути в
# результате абсолютные.
#
# Значения берутся из окружения (DEPLOY_DIR, SERVICE_USER, ONFAILURE), чтобы
# функция одинаково годилась и для systemd.sh, и для тестов.
unit_render() {
  local file="$1" stack="$2"
  sed \
    -e "s#@DEPLOY_DIR@#${DEPLOY_DIR:?}#g" \
    -e "s#@STACK_DIR@#${DEPLOY_DIR:?}/stacks/$stack#g" \
    -e "s#@SERVICE_USER@#${SERVICE_USER:?}#g" \
    -e "s#@ONFAILURE@#${ONFAILURE:-}#g" \
    "$file"
}

# ---------------------------------------------------------------- домены

# Домены включённых стеков, по одному на строку, без повторов.
#
# Отдельный список доменов (например, набор каталогов в getssl-config/)
# разъезжается с набором стеков незаметно в обе стороны: домен без стека
# продлевается вечно и тратит лимиты Let's Encrypt, а стек без домена молча
# остаётся с самоподписанной заглушкой до тех пор, пока кто-нибудь не откроет
# его в браузере.
# Одна запись Domains= — это ОДИН сертификат. Форма `домен+алиас+алиас`
# означает, что алиасы уходят в тот же сертификат как SANS.
#
# Без этого www-имя, которое обслуживает тот же server-блок, остаётся с
# сертификатом на голый домен: браузер ругается только на www, то есть отказ
# видно не всем и не сразу, а из логов nginx он не виден вовсе.
domain_primary() { printf '%s' "${1%%+*}"; }
domain_sans()    { [ "$1" = "${1#*+}" ] || printf '%s' "${1#*+}" | tr '+' ' '; }

# Основные домены включённых стеков — по одному на сертификат.
stacks_domains() {
  local s d
  while IFS= read -r s; do
    for d in $(stack_conf_get "$s" Domains); do printf '%s\n' "$(domain_primary "$d")"; done
  done < <(stacks_enabled 2>/dev/null) | sort -u
}

# Сырые записи Domains= включённых стеков — по одной на сертификат, вместе с
# алиасами. Это то, из чего certs.sh собирает per-host конфиги getssl.
stacks_domain_specs() {
  local s d
  while IFS= read -r s; do
    for d in $(stack_conf_get "$s" Domains); do printf '%s\n' "$d"; done
  done < <(stacks_enabled 2>/dev/null) | sort -u
}

# ВСЕ имена включённых стеков, включая алиасы. Это то, что обязан обслуживать
# работающий nginx, — в отличие от stacks_domains, которым меряют сертификаты.
stacks_domain_names() {
  local s d a
  while IFS= read -r s; do
    for d in $(stack_conf_get "$s" Domains); do
      printf '%s\n' "$(domain_primary "$d")"
      for a in $(domain_sans "$d"); do printf '%s\n' "$a"; done
    done
  done < <(stacks_enabled 2>/dev/null) | sort -u
}

# ------------------------------------------------- разбор compose-файла
#
# Имена сервисов, томов и образов читаем разбором yaml, а НЕ через
# `docker compose config`: последний требует все env-файлы стека и падает на
# стеке, который как раз выключен или сломан — то есть именно тогда, когда
# `stack.sh list` и `stack.sh purge` обязаны работать. Разбор рассчитан на
# формат этих файлов (два пробела отступа под `services:` / `volumes:`), а
# `stack.sh --check` сверяет результат с `docker compose config --services`
# для включённых стеков, чтобы расхождение не жило незамеченным.

_stacks_yaml_keys() {
  local file="$1" want="$2"
  [ -f "$file" ] || return 0
  awk -v want="$want" '
    /^services:/ { sect = "services"; next }
    /^volumes:/  { sect = "volumes";  next }
    /^[^[:space:]#]/ { sect = ""; next }
    sect == want && /^  [A-Za-z0-9_.-]+:[[:space:]]*(&[A-Za-z0-9_-]+)?[[:space:]]*(#.*)?$/ {
      key = $0
      sub(/^  /, "", key)
      sub(/:.*$/, "", key)
      print key
    }
  ' "$file"
}

# Сервисы, принадлежащие стеку.
#
# Сервисы платформы (nginx, php-fpm) исключаются намеренно: файл стека может
# домешивать в них том, и без этого фильтра `stack.sh disable` снёс бы контейнер
# nginx вместе со всеми сайтами машины.
stack_services() {
  local s="$1" base_services svc
  base_services=$(platform_services)
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    if printf '%s\n' "$base_services" | grep -qx -- "$svc"; then
      echo "Предупреждение: стек '$s' домешивает в общий сервис '$svc' — он не будет ни остановлен, ни удалён" >&2
      continue
    fi
    printf '%s\n' "$svc"
  done < <(_stacks_yaml_keys "$(stack_compose_file "$s")" services)
}

# Named volumes, объявленные стеком (bind-mount'ы сюда не попадают и не должны:
# данные на /mnt/data не удаляет никакая команда этого репозитория).
stack_volumes() { _stacks_yaml_keys "$(stack_compose_file "$1")" volumes; }

# Образы, на которые ссылается стек (в формате repository:tag или repository).
stack_images() {
  local f="$(stack_compose_file "$1")"
  [ -f "$f" ] || return 0
  awk '
    /^[[:space:]]+image:[[:space:]]*[^[:space:]]/ {
      v = $0
      sub(/^[[:space:]]*image:[[:space:]]*/, "", v)
      sub(/[[:space:]]+#.*$/, "", v)
      sub(/[[:space:]]*$/, "", v)
      print v
    }
  ' "$f" | tr -d '"'"'" | sort -u
}

# ------------------------------------------------------------------ nginx

# Строки include для включённых стеков, у которых есть непустой каталог
# vhost'ов.
#
# Порядок — по наименьшему имени файла внутри каталога, а не по алфавиту имён
# стеков. Причина конкретная: в default.conf нет `default_server`, поэтому
# сервером по умолчанию nginx считает ПЕРВЫЙ прочитанный vhost (сегодня это
# 01-webhooks). Алфавит по стекам поменял бы это молча.
stacks_include_lines() {
  local s dir first
  while IFS= read -r s; do
    dir="$(stack_vhost_dir "$s")"
    [ -d "$dir" ] || continue
    first=$(ls -1 "$dir"/*.conf 2>/dev/null | sed 's:.*/::' | sort | head -n 1)
    [ -n "$first" ] || continue
    printf '%s\t%s\n' "$first" "$s"
  done < <(stacks_enabled) | sort | while IFS=$'\t' read -r _ s; do
    printf 'include %s/nginx/*.conf;\n' "$(stack_dir_in_container "$s")"
  done
}

# Содержимое 00-enabled.conf для текущего манифеста.
stacks_include_content() {
  cat <<'HDR'
# СГЕНЕРИРОВАННЫЙ ФАЙЛ — правки будут перезаписаны.
# Создаётся scripts/stack.sh из Enabled_Stacks в .env-stacks.
#
# Смысл: nginx включает только conf.d/*.conf верхнего уровня, а vhost'ы стеков
# лежат вне conf.d — в смонтированном /etc/nginx/stacks/<стек>/nginx/. Читаются
# они ТОЛЬКО через include ниже, поэтому стек без строки здесь для nginx не
# существует.
HDR
  stacks_include_lines
}

# Содержимое platform/compose/nginx-static.generated.yaml.
#
# Собирается из Static= ВСЕХ стеков в stacks/, а не только включённых, и
# значения переносятся дословно, без разворачивания ${...}. Ровно это и делает
# текст файла независимым от Enabled_Stacks и от наличия .env у стеков: спека
# nginx, зависящая от набора стеков, означает, что выключение стека
# пересоздаёт nginx — а это уносит ВСЕ vhost'ы, а не только сайты выключаемого
# стека (CLAUDE.md §3.1).
#
# Файл генерируется, а не пишется руками: захардкоженное имя домена в общем
# файле означало бы правку платформы при каждом новом стеке со статикой.
stacks_static_content() {
  local s pair domain path lines=""
  while IFS= read -r s; do
    for pair in $(stack_conf_get "$s" Static); do
      domain="${pair%%:*}"
      path="${pair#*:}"
      lines="$lines      - $path:\${Platform_Vhosts_Mount:?задайте Platform_Vhosts_Mount в корневом .env}/$domain:ro"$'\n'
    done
  done < <(stacks_available)

  cat <<'HDR'
# СГЕНЕРИРОВАННЫЙ ФАЙЛ — правки будут перезаписаны.
# Создаётся scripts/stack.sh из Static= в stacks/*/stack.conf.
#
# Подключается ВСЕГДА, независимо от Enabled_Stacks, и собирается из всех
# стеков, а не из включённых. Это и есть его смысл: том со статикой домешивается
# в сервис nginx из platform/compose/nginx.yaml, и если бы он жил в файле стека,
# выключение стека МЕНЯЛО БЫ спеку nginx — то есть следующий `up -d` пересоздавал
# бы nginx со всеми последствиями из CLAUDE.md §3.1.
#
# Переменные не развёрнуты намеренно: их подставляет compose из корневого .env,
# который загружается всегда. Дефолт `:-./vhosts` в каждой из них обязателен —
# пустой host-путь означает каталог-пустышку от root и молчаливые 404.
HDR

  # Пустой блок volumes — невалидный yaml, и compose падал бы на КАЖДОЙ команде
  # на машине, где ни один стек статики не раздаёт.
  if [ -n "$lines" ]; then
    printf 'services:\n  nginx:\n    volumes:\n%s' "$lines"
  fi
}

# Имя compose-проекта. Берём с метки живого контейнера, а не из basename
# каталога: по метке работают все docker-команды disable/purge, и ошибиться
# здесь означало бы трогать чужие контейнеры.
compose_project() {
  local p
  p=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' nginx 2>/dev/null || true)
  if [ -n "$p" ] && [ "$p" != "<no value>" ]; then printf '%s' "$p"; return 0; fi
  basename "$(stacks_root)" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_-' '-' | sed 's/-*$//'
}

# Контейнеры сервиса (включая остановленные) по меткам compose.
service_containers() {
  local svc="$1" proj
  proj=$(compose_project)
  docker ps -aq \
    --filter "label=com.docker.compose.project=$proj" \
    --filter "label=com.docker.compose.service=$svc" 2>/dev/null || true
}

# Сервисы, объявленные платформой и ВСЕМИ стеками — включёнными и нет.
#
# Выключенный стек здесь намеренно считается «знакомым»: его оставшиеся
# контейнеры — это отдельная строка проверки («выключен, но остались
# контейнеры») с понятным лечением через stack.sh disable. Бесхозный — это
# другое: сервиса с таким именем не объявляет НИКТО.
stacks_known_services() {
  local s f
  for f in "$(stacks_root)"/platform/compose/*.yaml; do
    [ -f "$f" ] || continue
    _stacks_yaml_keys "$f" services
  done
  while IFS= read -r s; do
    stack_services "$s" 2>/dev/null || true
  done < <(stacks_available)
}

# Контейнеры проекта: «имя<TAB>сервис» по строке на контейнер, включая
# остановленные.
#
# Существует потому, что service_containers() ищет по ИМЕНАМ сервисов из
# compose-файлов и поэтому слеп к тому, чего в них нет. Контейнер
# переименованного или удалённого сервиса иначе не виден ни одной проверке, а
# для watch-host.sh он при этом вечная авария: остановлен, но с
# restart: unless-stopped.
project_containers() {
  local proj
  proj=$(compose_project)
  docker ps -a --filter "label=com.docker.compose.project=$proj" \
    --format '{{.Names}}	{{.Label "com.docker.compose.service"}}' 2>/dev/null || true
}

# ------------------------------------------------------- вывод таблиц

# Ширина строки в СИМВОЛАХ. `printf %-12s` считает байты, поэтому таблица с
# русскими значениями («вкл», «выкл», «ок») разъезжается тем сильнее, чем
# больше в ней кириллицы. Считаем байты, кроме продолжающих байтов UTF-8
# (0x80-0xBF) — это не зависит от локали, а `${#s}` зависит: под LANG=C bash
# посчитает те же байты.
#
# Живёт здесь, а не в stack.sh: таблицу со стеками печатает не он один.
_vislen() { LC_ALL=C printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c | tr -d ' \n'; }

# Ячейка таблицы: текст, добитый пробелами до нужной ширины.
_cell() {
  local text="$1" width="$2" len
  len=$(_vislen "$text")
  printf '%s' "$text"
  while [ "$len" -lt "$width" ]; do printf ' '; len=$((len + 1)); done
}

# -------------------------------------------- живой nginx против спеки

# «источник<TAB>цель» по каждому bind-mount'у из рендера `docker compose
# config`. Читает stdin.
#
# Спека контейнера и его живое состояние — разные вещи: правка `volumes`
# применяется только пересозданием. До него `docker ps` показывает контейнер
# работающим, `nginx -t` внутри него проходит, и ничто не намекает, что nginx
# смотрит в каталоги, которых на диске уже нет.
compose_mount_pairs() {
  awk '
    $1 == "-" && $2 == "type:"      { ty = $3; src = "" }
    $1 == "source:" && ty == "bind" { src = $2; gsub(/^"|"$/, "", src) }
    $1 == "target:" && src != ""    { tgt = $2; gsub(/^"|"$/, "", tgt)
                                      printf "%s\t%s\n", src, tgt; src = "" }
  '
}

# Домены, которые РЕАЛЬНО обслуживает работающий nginx. Читает вывод
# `nginx -T`, то есть эффективную конфигурацию процесса, а не файлы на диске.
#
# `nginx -t` на этот вопрос не отвечает: конфигурация без единого server-блока
# синтаксически верна и проверку синтаксиса проходит — при том что nginx в
# таком состоянии не слушает вообще ничего.
nginx_served_names() {
  awk '$1 == "server_name" {
         for (i = 2; i <= NF; i++) { gsub(/;/, "", $i); if ($i != "" && $i != "_") print $i }
       }' | sed '/^$/d' | sort -u
}

# ------------------------------------------------------ юниты на машине

# Каталог юнитов systemd. Переопределяется только ради тестов: на машине это
# всегда /etc/systemd/system, и юниты там лежат плоско — отсюда требование
# префикса devbox-<стек>- в имени.
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"

# Юниты стека, РЕАЛЬНО установленные на машине, по одному имени на строку.
#
# Объявленные (stack_units) и установленные — разные множества, и расходятся
# они молча в обе стороны: у включённого стека юнит может быть не поставлен, у
# выключенного — остаться и будить машину по таймеру мёртвого стека.
stack_units_installed() {
  local s="$1" u n
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    n="$(basename "$u")"
    [ -e "$SYSTEMD_UNIT_DIR/$n" ] && printf '%s\n' "$n"
  done < <(stack_units "$s")
  return 0
}

# --------------------------------------------------- здоровье стеков

# Проверка живости стека, если стек её объявил. Наличие файла — и есть
# объявление: отдельного списка нет, как и у vhost'ов, юнитов и logrotate.
stack_health_script() { printf '%s/scripts/health.sh' "$(stack_dir "$1")"; }

