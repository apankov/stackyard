#!/usr/bin/env bash

# Тесты движков платформы на синтетических стеках.
#
#   ./platform/bin/selftest.sh
#
# Существует потому, что проверить генераторы на боевой машине нельзя, не
# сломав её: неверный 00-enabled.conf — это отсутствие всех vhost'ов сразу, а
# неверный nginx-static — пересоздание nginx. Здесь ROOT_DIR подменяется на
# временный каталог с парой выдуманных стеков, и проверяется ровно тот текст,
# который генераторы производят.
#
# На shell, а не на чём-то ещё, по той же причине, по которой на shell написан
# сам предмет: на девбоксе нет ни одного рантайма, и харнесс на другом языке
# проверял бы что-то другое.

set -uo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Корень stackyard, а не машины: предмет здесь — сам движок.
REPO_DIR="$( cd "$DIR0/../.." && pwd )"
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"

# Машины-фикстуры. Их две и с РАЗНЫМИ СУБД намеренно: платформа считается общей
# ровно тогда, когда обе работают на ней без единой правки, и проверить это
# можно только прогнав движок на обеих.
FIXTURES="$REPO_DIR/tests/machines"

failures=0
check() {
  if [ "$2" = "$3" ]; then
    printf '  ✓ %s\n' "$1"
  else
    printf '  ✗ %s\n    ожидалось: [%s]\n    получено:  [%s]\n' "$1" "$3" "$2"
    failures=$((failures + 1))
  fi
}

# fixture <имя-стека> <файл-относительно-стека> <содержимое>
# Создаёт файл внутри $WORK/stacks/<имя>/, заводя каталоги по пути.
fixture() {
  local stack="$1" rel="$2" content="$3"
  mkdir -p "$WORK/stacks/$stack/$(dirname "$rel")"
  printf '%s\n' "$content" > "$WORK/stacks/$stack/$rel"
  # Стеком каталог делает stack.conf, а не сам факт существования — иначе
  # stacks/<стек>/.env, который машина заводит ЛЮБОМУ стеку, объявлял бы стек.
  # Фикстура, задающая только vhost или только compose, без этого не видна
  # движку вовсе, и половина тестов проверяла бы пустоту.
  [ -f "$WORK/stacks/$stack/stack.conf" ] || : > "$WORK/stacks/$stack/stack.conf"
}

# fixture_root <корень> <стек> <файл> <содержимое>
# То же, но в указанный корень: проверяем, что движок видит стеки и в машинном
# stacks/, и в профильном profile/stacks/, и что машинный перекрывает профиль.
fixture_root() {
  local root="$1" stack="$2" rel="$3" content="$4"
  mkdir -p "$WORK/$root/$stack/$(dirname "$rel")"
  printf '%s\n' "$content" > "$WORK/$root/$stack/$rel"
  [ -f "$WORK/$root/$stack/stack.conf" ] || : > "$WORK/$root/$stack/stack.conf"
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/platform/lib" "$WORK/platform/nginx-vhosts" "$WORK/platform/compose" "$WORK/state" "$WORK/stacks"
# Обе библиотеки: lib-stacks.sh читает stack.conf без подстановок, lib-env.sh
# нужен для stack_backup_sources, где подстановки как раз разворачиваются.
cp "$LIB_DIR/lib-stacks.sh" "$LIB_DIR/lib-env.sh" "$WORK/platform/lib/"
printf 'services:\n  nginx:\n    image: nginx\n' > "$WORK/platform/compose/nginx.yaml"

# Читается подключаемыми ниже библиотеками, а не этим файлом.
# shellcheck disable=SC2034
ROOT_DIR="$WORK"
# shellcheck source=lib-stacks.sh
. "$WORK/platform/lib/lib-stacks.sh"
# shellcheck source=lib-env.sh
. "$WORK/platform/lib/lib-env.sh"

echo "== include'ы vhost'ов"

# Два стека, у которых префиксы файлов идут ВРАЗРЕЗ с алфавитом имён: alpha
# получает 20-, zulu — 10-. Порядок include'ов обязан следовать префиксам, а
# не именам стеков — от него зависит, какой vhost nginx читает первым.
fixture alpha stack.conf 'Requires=""'
fixture alpha compose.yaml 'services:
  alpha-app:
    image: alpine'
fixture alpha nginx/20-alpha.test.conf 'server {
    server_name alpha.test;
}'
fixture zulu stack.conf 'Requires=""'
fixture zulu compose.yaml 'services:
  zulu-app:
    image: alpine'
fixture zulu nginx/10-zulu.test.conf 'server {
    server_name zulu.test;
}'
printf 'Enabled_Stacks="alpha zulu"\n' > "$WORK/.env-stacks"

got=$(stacks_include_lines)
want='include /etc/nginx/stacks/zulu/nginx/*.conf;
include /etc/nginx/stacks/alpha/nginx/*.conf;'
check "порядок include'ов следует префиксам файлов, а не именам стеков" "$got" "$want"

echo "== stack.conf"

fixture bravo stack.conf 'Requires="pg qdrant"
Domains="bravo.test"
Static="bravo.test:${Bravo_Static_Dir:-./vhosts}/public"'
fixture bravo compose.yaml 'services:
  bravo-app:
    image: alpine'

check "Requires читается" "$(stack_conf_get bravo Requires)" "pg qdrant"
check "Domains читается" "$(stack_conf_get bravo Domains)" "bravo.test"
# Ключевое свойство: платформа НЕ разворачивает ${...} в Static. Развернуть его
# здесь означало бы, что текст спеки nginx зависит от того, есть ли у стека
# .env — то есть от того, включён ли он.
check "Static отдаётся дословно, без подстановки" \
  "$(stack_conf_get bravo Static)" 'bravo.test:${Bravo_Static_Dir:-./vhosts}/public'
check "отсутствующий ключ даёт умолчание" "$(stack_conf_get bravo Nope def)" "def"
check "стек без stack.conf не роняет чтение" "$(stack_conf_get nosuch Domains)" ""
check "stack_requires читает из файла" "$(stack_requires bravo)" "pg qdrant"

echo "== генерация статики"

fixture charlie stack.conf 'Static="charlie.test:${Charlie_Dir:-./vhosts}/pub"'
fixture charlie compose.yaml 'services:
  charlie-app:
    image: alpine'

printf 'Enabled_Stacks="alpha zulu bravo charlie"\n' > "$WORK/.env-stacks"
with_all=$(stacks_static_content)
printf 'Enabled_Stacks="alpha"\n' > "$WORK/.env-stacks"
with_one=$(stacks_static_content)

# Главный инвариант: текст спеки nginx одинаков при любом составе включённых
# стеков. Иначе выключение стека меняет спеку, а следующий up -d пересоздаёт
# nginx — способ уронить все сайты разом (CLAUDE.md §3.1).
check "текст статики не зависит от Enabled_Stacks" "$with_all" "$with_one"
check "объявленный том попал в файл" \
  "$(printf '%s' "$with_all" | grep -c 'charlie.test')" "1"
check "подстановка не развёрнута" \
  "$(printf '%s' "$with_all" | grep -c '${Charlie_Dir:-./vhosts}')" "1"

# Стеки без Static не должны порождать пустой блок volumes: это невалидный
# yaml, и compose падал бы на КАЖДОЙ команде.
rm -f "$WORK/stacks/charlie/stack.conf" "$WORK/stacks/bravo/stack.conf"
check "без единого Static получается валидный файл без volumes" \
  "$(stacks_static_content | grep -c 'volumes:')" "0"

echo "== домены"

fixture delta stack.conf 'Domains="d1.test d2.test"'
fixture delta compose.yaml 'services:
  delta-app:
    image: alpine'
fixture bravo stack.conf 'Domains="bravo.test"'
printf 'Enabled_Stacks="delta bravo"\n' > "$WORK/.env-stacks"

check "домены собираются по включённым стекам, без повторов и отсортированно" \
  "$(stacks_domains | tr '\n' ' ')" "bravo.test d1.test d2.test "

printf 'Enabled_Stacks="bravo"\n' > "$WORK/.env-stacks"
check "выключенный стек доменов не даёт" "$(stacks_domains | tr '\n' ' ')" "bravo.test "

echo "== юниты стеков"

fixture echo1 stack.conf 'Requires=""'
fixture echo1 compose.yaml 'services:
  echo1-app:
    image: alpine'
fixture echo1 systemd/devbox-echo1-job.service '[Service]
ExecStart=@STACK_DIR@/scripts/job.sh
WorkingDirectory=@DEPLOY_DIR@
User=@SERVICE_USER@
@ONFAILURE@'

check "юниты стека находятся по каталогу, без объявления в stack.conf" \
  "$(stack_units echo1 | while IFS= read -r f; do basename "$f"; done | tr '\n' ' ')" \
  "devbox-echo1-job.service "
check "стек без каталога systemd/ юнитов не даёт" "$(stack_units alpha)" ""

rendered=$(DEPLOY_DIR=/opt/devbox SERVICE_USER=ec2-user ONFAILURE='OnFailure=x.service' \
           unit_render "$WORK/stacks/echo1/systemd/devbox-echo1-job.service" echo1)
check "@STACK_DIR@ подставлен" \
  "$(printf '%s' "$rendered" | grep -c '/opt/devbox/stacks/echo1/scripts/job.sh')" "1"
check "@DEPLOY_DIR@ подставлен" \
  "$(printf '%s' "$rendered" | grep -c '^WorkingDirectory=/opt/devbox$')" "1"
# Плейсхолдер, оставшийся в юните, systemd молча проглотит как часть пути, и
# таймер будет запускать несуществующую команду каждую ночь.
check "плейсхолдеров не осталось" \
  "$(printf '%s' "$rendered" | grep -c '@[A-Z_]*@')" "0"

# Объявленный юнит и установленный — разные множества. Их расхождение и есть
# то, что enable/disable теперь чинят сами, а --check ловит, когда не вышло:
# у включённого стека задача не выполняется вовсе, у выключенного машина
# просыпается по таймеру мёртвого стека.
mkdir -p "$WORK/systemd-units"
# Читается lib-stacks.sh, а не этим файлом.
# shellcheck disable=SC2034
SYSTEMD_UNIT_DIR="$WORK/systemd-units"
check "объявленный, но не установленный юнит в списке установленных не значится" \
  "$(stack_units_installed echo1)" ""
: > "$WORK/systemd-units/devbox-echo1-job.service"
check "установленный юнит стека виден" \
  "$(stack_units_installed echo1)" "devbox-echo1-job.service"
check "чужой юнит в каталоге стеку не приписывается" \
  "$(: > "$WORK/systemd-units/devbox-other-job.service"; stack_units_installed echo1)" \
  "devbox-echo1-job.service"

echo "== источники бэкапа"

fixture foxtrot stack.conf 'Backup_Sqlite="${Foxtrot_DB_Dir}/${Foxtrot_DB_File}"
Backup_Files="/mnt/data/foxtrot"
Backup_Volume="foxtrot-data"'
fixture foxtrot compose.yaml 'services:
  foxtrot-app:
    image: alpine'
printf 'Foxtrot_DB_Dir=/mnt/data/fox\nFoxtrot_DB_File=f.db\n' > "$WORK/stacks/foxtrot/.env"
printf 'Enabled_Stacks="foxtrot bravo"\n' > "$WORK/.env-stacks"

# Здесь подстановка РАЗВОРАЧИВАЕТСЯ, в отличие от Static: backup.sh работает
# только по включённым стекам, а у включённого стека .env есть по построению.
check "Backup_Sqlite развёрнут из .env стека" \
  "$(stack_backup_sources foxtrot | grep '^sqlite:')" "sqlite:/mnt/data/fox/f.db"
check "Backup_Files попал в список" \
  "$(stack_backup_sources foxtrot | grep '^files:')" "files:/mnt/data/foxtrot"
check "Backup_Volume попал в список" \
  "$(stack_backup_sources foxtrot | grep '^volume:')" "volume:foxtrot-data"
check "стек без объявлений даёт пусто" "$(stack_backup_sources bravo)" ""

# Главная защита: забытая переменная в .env стека свернула бы путь в
# оканчивающийся слэшем, и бэкап источника молча перестал бы сниматься.
# Отсутствующий бэкап выглядит ровно как источник, которого нет, поэтому
# молчать здесь нельзя.
printf 'Foxtrot_DB_Dir=/mnt/data/fox\n' > "$WORK/stacks/foxtrot/.env"
stack_backup_sources foxtrot >/dev/null 2>&1
check "неразвёрнутая подстановка — отказ, а не пустой путь" "$?" "1"
check "и отказ объясняет, чего не хватает" \
  "$(stack_backup_sources foxtrot 2>&1 >/dev/null | grep -c 'Foxtrot_DB_File')" "1"

# Значения соседнего стека не должны протекать в подстановки этого.
printf 'Foxtrot_DB_Dir=/mnt/data/fox\nFoxtrot_DB_File=f.db\n' > "$WORK/stacks/foxtrot/.env"
stack_backup_sources foxtrot >/dev/null
check "окружение стека не протекает в следующий" "$(stack_backup_sources bravo)" ""

echo "== проверки"

# Стек, нарушающий сразу всё: домен-дубль с delta, относительный host-путь,
# vhost с чужим server_name, юнит без префикса и таймер без проверки.
fixture golf stack.conf 'Domains="d1.test"'
fixture golf compose.yaml 'services:
  golf-app:
    image: alpine
    volumes:
      - ./relative/path:/data
      - /abs/hardcoded:/other
      - ${Golf_Home_Dir}/ok:/fine
      - somevolume:/named'
# Настоящие vhost'ы держат server_name отдельной строкой — фикстура обязана
# выглядеть так же, иначе тест проверяет разбор, которого в жизни не бывает.
fixture golf nginx/50-golf.conf 'server {
    listen      80;
    server_name other.test;
}'
fixture golf systemd/wrong-name.timer '[Timer]
OnCalendar=daily'
fixture golf systemd/devbox-golf-job.timer '[Timer]
OnCalendar=daily'
printf 'Enabled_Stacks="golf delta"\n' > "$WORK/.env-stacks"

check "дубль домена найден" "$(check_domains_unique | wc -l | tr -d ' ')" "1"
check "домен без vhost и vhost без домена — обе стороны" \
  "$(check_domains_match golf | wc -l | tr -d ' ')" "2"
# CLAUDE.md §7 требует от host-пути обоих свойств сразу: абсолютный И через
# переменную. Проверяются обе половины, поэтому находок здесь две: относительный
# путь и захардкоженный. Путь через переменную и именованный том — не находки.
check "относительный и захардкоженный host-пути найдены, оба вида корректных — нет" \
  "$(check_paths_absolute golf | wc -l | tr -d ' ')" "2"
check "захардкоженный путь назван именно захардкоженным" \
  "$(check_paths_absolute golf | grep -c 'захардкоженный')" "1"
check "имя юнита без префикса найдено" "$(check_unit_names golf | wc -l | tr -d ' ')" "1"
check "таймер без проверки найден" \
  "$(check_timer_has_check golf | grep -c 'devbox-golf-job')" "1"
check "у корректного стека претензий по путям нет" \
  "$(check_paths_absolute delta | wc -l | tr -d ' ')" "0"

# Таймер, у которого проверка есть, претензий вызывать не должен.
fixture golf scripts/check-job.sh '#!/bin/sh
exit 0'
check "таймер с scripts/check-<задача>.sh претензий не вызывает" \
  "$(check_timer_has_check golf | grep -c 'devbox-golf-job')" "0"

# Цикл в Requires: hotel -> india -> hotel.
fixture hotel stack.conf 'Requires="india"'
fixture hotel compose.yaml 'services:
  hotel-app:
    image: alpine'
fixture india stack.conf 'Requires="hotel"'
fixture india compose.yaml 'services:
  india-app:
    image: alpine'
check "цикл в Requires найден" "$(check_requires_cycle hotel | wc -l | tr -d ' ')" "1"
check "стек без зависимостей цикла не даёт" "$(check_requires_cycle delta)" ""

# Домешивание в общий сервис nginx — та самая поломка, ради которой есть Static=.
fixture juliet stack.conf 'Requires=""'
fixture juliet compose.yaml 'services:
  nginx:
    volumes:
      - /x:/y'
check "домешивание в общий сервис nginx найдено" \
  "$(check_no_base_service_merge juliet | wc -l | tr -d ' ')" "1"
check "обычный стек в общий сервис не лезет" "$(check_no_base_service_merge delta)" ""

echo "== проверки под set -e"

# Этот файл работает под `set -uo pipefail`, а stack.sh — под `set -euo
# pipefail`, и разница не косметическая. Упавший `grep` (нет каталога nginx/ у
# стека, нет совпадений в нём) под `set -e` убивает подоболочку цикла целиком,
# и функция возвращает ПУСТО вместо находок — то есть проверка тихо перестаёт
# проверять. Именно так блок «Upstream'ы включённых vhost'ов» в `stack.sh
# --check` печатался пустым: pg идёт в манифесте первым и nginx/ у него нет.
#
# Поэтому функции, чей результат читает stack.sh, гоняются ещё и так, как их
# зовёт он: под errexit и НЕ в составе `&&` — иначе bash отключает errexit
# внутри функции, и тест проверял бы не то, что происходит на машине.
errexit_run() {
  bash -c '
    set -euo pipefail
    ROOT_DIR="$1"; shift
    . "$ROOT_DIR/platform/lib/lib-stacks.sh"
    . "$ROOT_DIR/platform/lib/lib-env.sh"
    "$@"
  ' _ "$WORK" "$@" 2>/dev/null
}

# mike — стек без vhost'ов, но с объявленным доменом, и в манифесте он ПЕРВЫЙ:
# на нём и умирал обход. november — обычный стек с proxy_pass.
fixture mike stack.conf 'Domains="mike.test"'
fixture mike compose.yaml 'services:
  mike-app:
    image: alpine'
fixture november stack.conf 'Requires=""'
fixture november compose.yaml 'services:
  november-app:
    image: alpine'
fixture november nginx/70-november.test.conf 'server {
    server_name november.test;
    location / {
        proxy_pass http://november-app:3000;
    }
}'
printf 'Enabled_Stacks="mike november"\n' > "$WORK/.env-stacks"

check "upstream'ы находятся, хотя первый стек манифеста без nginx/" \
  "$(errexit_run stacks_upstreams)" "november-app"
check "домен без vhost'а находится под set -e" \
  "$(errexit_run check_domains_match mike | wc -l | tr -d ' ')" "1"
check "vhost без домена находится под set -e" \
  "$(errexit_run check_domains_match november | wc -l | tr -d ' ')" "1"

# Код возврата проверки обязан означать «проверить не удалось», а не «претензий
# нет»: иначе первый же вызов через `||` сработает наоборот.
errexit_run check_no_base_service_merge november >/dev/null
check "чистый стек не выглядит как ошибка по коду возврата" "$?" "0"

# Список знакомых сервисов — по ВСЕМ стекам, а не по включённым. Иначе
# контейнер выключенного стека объявлялся бы бесхозным, и «выключен, но
# остались контейнеры» (лечится через stack.sh disable) слилось бы с «сервиса
# не объявляет никто» (лечится docker rm -f). Это разные диагнозы.
known=$(errexit_run stacks_known_services | sed '/^$/d' | sort -u)
check "платформенный nginx — знакомый сервис" \
  "$(printf '%s\n' "$known" | grep -cx 'nginx')" "1"
check "сервис включённого стека — знакомый" \
  "$(printf '%s\n' "$known" | grep -cx 'november-app')" "1"
check "сервис ВЫКЛЮЧЕННОГО стека тоже знакомый" \
  "$(printf '%s\n' "$known" | grep -cx 'golf-app')" "1"
check "сервиса, которого не объявляет никто, в списке нет" \
  "$(printf '%s\n' "$known" | grep -cx 'quotrum-website')" "0"

echo "== живой nginx против спеки"

# Рендер `docker compose config`: тома в длинной форме, порты рядом и тоже с
# ключом target. Порт не должен попасть в список монтирований — иначе
# сравнение с живым контейнером даёт вечное расхождение.
got=$(compose_mount_pairs <<'YAML'
  nginx:
    ports:
      - mode: ingress
        target: 80
        published: "80"
    volumes:
      - type: bind
        source: /srv/repo/platform/nginx-vhosts
        target: /etc/nginx/conf.d
        bind: {}
      - type: bind
        source: /srv/repo/stacks
        target: /etc/nginx/stacks
        read_only: true
        bind: {}
      - type: volume
        source: somevolume
        target: /data
YAML
)
want="/srv/repo/platform/nginx-vhosts	/etc/nginx/conf.d
/srv/repo/stacks	/etc/nginx/stacks"
check "монтирования разобраны, порт и именованный том — нет" "$got" "$want"

# Вывод `nginx -T`: имён в директиве может быть несколько, `_` — это не домен.
got=$(nginx_served_names <<'CONF'
server {
    listen 80 default_server;
    server_name _;
}
server {
    listen 443 ssl;
    server_name api.test  www.api.test;
}
server {
    server_name api.test;
}
CONF
)
check "домены работающего nginx разобраны, без повторов и без _" \
  "$got" "api.test
www.api.test"

# Конфигурация без единого server-блока синтаксически верна: nginx с ней
# проходит `nginx -t` и не слушает ничего. Пустой список здесь — это отказ,
# который --check обязан заметить.
check "конфигурация без server-блоков даёт пустой список" \
  "$(printf 'events {}\nhttp {\n  include /etc/nginx/conf.d/*.conf;\n}\n' | nginx_served_names)" ""

echo "== здоровье стеков"

# Наличие файла — и есть объявление: отдельного списка проверок нет.
fixture oscar stack.conf 'Requires=""'
fixture oscar compose.yaml 'services:
  oscar-app:
    image: alpine'
fixture oscar scripts/health.sh '#!/bin/sh
exit 0'
check "проверка живости стека находится по пути" \
  "$(errexit_run stack_health_script oscar)" "$WORK/stacks/oscar/scripts/health.sh"
check "у стека без неё пути нет на диске" \
  "$([ -f "$(errexit_run stack_health_script november)" ] && echo есть || echo нет)" "нет"

echo "== базы у поставщика"

# Поставщик БД — РОЛЬ, а не имя. Стек объявляет Provides_DB=<префикс>, и движок
# собирает заказы по этому префиксу, не зная ни слова «Postgres», ни «MySQL».
# Проверяем на ВЫДУМАННОМ префиксе: если тест пройдёт с ним, значит в движке не
# осталось зашитого имени ни одной настоящей СУБД.
fixture papa stack.conf 'Provides_DB="Zulu"
DB_Init_Service="zulu-init"'
fixture papa compose.yaml 'services:
  zulu:
    image: alpine'

fixture kilo stack.conf 'Requires="papa"
Zulu_DB="${Kilo_DB_Name}"
Zulu_User="${Kilo_DB_User}"
Zulu_Password="${Kilo_DB_Password}"'
fixture kilo compose.yaml 'services:
  kilo-app:
    image: alpine'
printf 'Kilo_DB_Name=kilo_stg\nKilo_DB_User=kilo\nKilo_DB_Password=p@ss'"'"'w0rd\n' \
  > "$WORK/stacks/kilo/.env"
fixture lima stack.conf 'Zulu_DB="lima"
Zulu_User="lima"
Zulu_Password="secret"
Zulu_Dump="lima-seed.sql"'
fixture lima compose.yaml 'services:
  lima-app:
    image: alpine'
printf 'Enabled_Stacks="papa kilo lima alpha"\n' > "$WORK/.env-stacks"

check "поставщик находится по роли" "$(stacks_db_provider)" "papa"
check "префикс заказов взят у поставщика" "$(stacks_db_prefix)" "Zulu"
check "имя инициализатора взято у поставщика" "$(stacks_db_init_service)" "zulu-init"
check "файл со списком баз лежит в state машины" \
  "$(stacks_databases_file)" "$WORK/state/papa/databases.yaml"

yaml=$(stacks_databases_content)
check "объявленная база попала в yaml" "$(printf '%s' "$yaml" | grep -c '^- db:')" "2"
check "имя базы развёрнуто из .env стека" \
  "$(printf '%s' "$yaml" | grep -c "db: 'kilo_stg'")" "1"
# Пароль с апострофом обязан пережить YAML: в одинарных кавычках он удваивается.
# Иначе инициализатор прочитает обрезанный пароль и заведёт пользователя, под
# которым приложение не подключится, — то есть ровно ту поломку, от которой вся
# эта генерация и затевалась.
check "апостроф в пароле экранирован" \
  "$(printf '%s' "$yaml" | grep -c "password: 'p@ss''w0rd'")" "1"
check "необязательный ключ попал, где объявлен" \
  "$(printf '%s' "$yaml" | grep -c "dump: 'lima-seed.sql'")" "1"
check "стек без объявления в yaml не попадает" \
  "$(printf '%s' "$yaml" | grep -c 'alpha')" "0"

# Выключенному стеку базу заводить незачем. Обратной поломки нет: инициализатор
# ничего не удаляет, поэтому disable базу не трогает, а enable её вернёт.
printf 'Enabled_Stacks="papa lima"\n' > "$WORK/.env-stacks"
check "выключенный стек базу не объявляет" \
  "$(stacks_databases_content | grep -c 'kilo')" "0"

# Без включённого поставщика заказывать не у кого — и это законное состояние, а
# не поломка: машине с одним прокси-стеком общая СУБД не нужна.
printf 'Enabled_Stacks="lima"\n' > "$WORK/.env-stacks"
check "без поставщика yaml пуст" "$(stacks_databases_content)" ""
check "без поставщика путь к файлу пуст" "$(stacks_databases_file)" ""
printf 'Enabled_Stacks="papa lima"\n' > "$WORK/.env-stacks"

# Частичная декларация — отказ, а не половина записи: пользователь без пароля
# был бы создан с пустым паролем и пустил бы кого угодно, кто дотянется до порта.
fixture mike stack.conf 'Zulu_DB="mike"'
fixture mike compose.yaml 'services:
  mike-app:
    image: alpine'
printf 'Enabled_Stacks="papa lima mike"\n' > "$WORK/.env-stacks"
check "частичная декларация найдена" "$(check_db_decl mike | wc -l | tr -d ' ')" "1"
check "полная декларация претензий не вызывает" "$(check_db_decl lima)" ""
check "стек без заказа претензий не вызывает" "$(check_db_decl alpha)" ""

# Два стека на одну базу — спор за владельца и почти наверняка опечатка.
fixture november stack.conf 'Zulu_DB="lima"
Zulu_User="november"
Zulu_Password="x"'
fixture november compose.yaml 'services:
  november-app:
    image: alpine'
printf 'Enabled_Stacks="papa lima november"\n' > "$WORK/.env-stacks"
check "дубль имени базы найден" "$(check_databases_unique | wc -l | tr -d ' ')" "1"

# Двух поставщиков быть не может: заказы различаются префиксом, а не адресатом,
# и второй с тем же префиксом тихо перехватывал бы чужие декларации.
fixture quebec stack.conf 'Provides_DB="Zulu"
DB_Init_Service="other-init"'
fixture quebec compose.yaml 'services:
  quebec:
    image: alpine'
printf 'Enabled_Stacks="papa quebec"\n' > "$WORK/.env-stacks"
check "два поставщика сразу найдены" "$(check_db_providers_unique | wc -l | tr -d ' ')" "1"
printf 'Enabled_Stacks="papa lima november"\n' > "$WORK/.env-stacks"

echo "== реестры образов"

# Стек, который тянет готовый образ из ECR и пинится по digest'у, — та самая
# раскладка, ради которой существует scripts/registry.sh.
fixture oscar stack.conf 'Image_Tag="master"'
fixture oscar compose.yaml 'services:
  oscar-app:
    image: 111.dkr.ecr.eu-north-1.amazonaws.com/oscar@${Oscar_Image_Digest:?not set in stacks/oscar/.env — run ./scripts/registry.sh pin oscar}'
# papa — образ из реестра, но Image_Tag не объявлен: digest обновлять нечем.
fixture papa compose.yaml 'services:
  papa-app:
    image: 111.dkr.ecr.eu-north-1.amazonaws.com/papa@${Papa_Image_Digest}'
# quebec — Image_Tag объявлен, а образ с Docker Hub: пинить нечего.
fixture quebec stack.conf 'Image_Tag="master"'
fixture quebec compose.yaml 'services:
  quebec-app:
    image: alpine:3.20'
printf 'Enabled_Stacks="oscar papa quebec"\n' > "$WORK/.env-stacks"

# Значение `image:` берётся целиком: в подстановке с `:?` есть пробелы, и
# обрезка по ним оставила бы половину имени образа — а по нему purge ищет, что
# удалять с диска.
check 'имя образа с пробелами в подстановке не обрезается' \
  "$(stack_images oscar)" \
  '111.dkr.ecr.eu-north-1.amazonaws.com/oscar@${Oscar_Image_Digest:?not set in stacks/oscar/.env — run ./scripts/registry.sh pin oscar}'

check "реестр у образа Docker Hub пустой" "$(image_registry 'alpine:3.20')" ""
check "реестр у образа с путём, но без точки, пустой" "$(image_registry 'library/alpine:3.20')" ""
check "реестр ECR распознан" \
  "$(image_registry '111.dkr.ecr.eu-north-1.amazonaws.com/oscar@sha256:ab')" \
  "111.dkr.ecr.eu-north-1.amazonaws.com"
check "реестр с портом распознан" "$(image_registry 'localhost:5000/x')" "localhost:5000"

check "стек с Hub-образом внешних реестров не даёт" "$(stack_registry_images quebec)" ""
check "реестры перечисленных стеков" "$(stacks_registries oscar quebec)" \
  "111.dkr.ecr.eu-north-1.amazonaws.com"

# Тег без digest'а и digest без тега — половины одной пары, и каждая по
# отдельности бесполезна: записывать резолв некуда либо обновлять нечем.
check "digest без Image_Tag найден" "$(check_image_decl papa | wc -l | tr -d ' ')" "1"
check "Image_Tag без внешнего реестра найден" "$(check_image_decl quebec | wc -l | tr -d ' ')" "1"
check "согласованная пара претензий не вызывает" "$(check_image_decl oscar)" ""

# Стек вовсе без образов из реестра не должен убивать обход под errexit: в
# манифесте он бывает первым, и тогда список реестров получился бы пустым.
check "реестры находятся под set -e, хотя первый стек манифеста без реестра" \
  "$(errexit_run stacks_registries quebec oscar)" "111.dkr.ecr.eu-north-1.amazonaws.com"

echo "== раскладка профиля и фикстур"

# Эти проверки идут по РЕАЛЬНЫМ файлам, а не по фикстуре из mktemp: предмет
# здесь — сами стеки профиля и машин-фикстур, и разъехаться они могут только
# там.

check "профильные стеки объявляют stack.conf" \
  "$(ls "$REPO_DIR"/profiles/stacks/*/stack.conf 2>/dev/null | wc -l | tr -d ' ')" \
  "$(ls -d "$REPO_DIR"/profiles/stacks/*/ 2>/dev/null | wc -l | tr -d ' ')"

# Ровно один поставщик БД на префикс. Два стека с одним Provides_DB в профиле
# означали бы, что машина, включившая оба, тихо получает чужие заказы.
dupe_prefix=$(grep -h '^Provides_DB=' "$REPO_DIR"/profiles/stacks/*/stack.conf 2>/dev/null \
              | cut -d= -f2- | tr -d '"' | sort | uniq -d)
check "префиксы поставщиков в профиле уникальны" "$dupe_prefix" ""

# У поставщика обязан быть хук дампов: без него backup.sh молча не снимет ни
# одной базы, а check-backups.sh не сможет построить ожидаемый список.
for d in "$REPO_DIR"/profiles/stacks/*/; do
  name=$(basename "${d%/}")
  grep -q '^Provides_DB=' "$d/stack.conf" 2>/dev/null || continue
  check "поставщик $name: есть scripts/backup-dump.sh" \
    "$([ -x "$d/scripts/backup-dump.sh" ] && echo да || echo нет)" "да"
  check "поставщик $name: хук отвечает на ext" \
    "$(ROOT_DIR="$REPO_DIR" STACK_DIR="$d" "$d/scripts/backup-dump.sh" ext 2>/dev/null | head -c 1)" "."
done

# Движок обязан обслуживать ОБЕ машины-фикстуры без правок. Они с разными
# СУБД намеренно: платформа считается общей ровно тогда, когда обе работают.
for m in "$FIXTURES"/*/; do
  [ -d "$m" ] || continue
  name=$(basename "${m%/}")
  [ -f "$m/.env-stacks" ] || { printf '  · фикстура %s не настроена, пропускаю\n' "$name"; continue; }

  # Domains и server_name — два списка одного и того же. Разъезд означает либо
  # сертификат, который выпускается и никому не служит, либо vhost, работающий
  # до первого посетителя.
  declared=$( ROOT_DIR="$m" bash -c ". \"$LIB_DIR/lib-stacks.sh\"; stacks_domain_names" 2>/dev/null )
  served=$(grep -rhE '^[[:space:]]*server_name[[:space:]]' "$m"/stacks/*/nginx/*.conf 2>/dev/null \
           | awk '{for (i = 2; i <= NF; i++) print $i}' | tr -d ';' | sed '/^$/d' | sort -u)
  check "$name: Domains совпадают с server_name" "$declared" "$served"

  # Стек без compose.yaml обязан объявить это явно. Молчаливая терпимость
  # превращала бы забытый файл в «стек без контейнеров».
  bad=""
  for d in "$m"/stacks/*/; do
    [ -f "$d/stack.conf" ] || continue
    [ -f "$d/compose.yaml" ] && continue
    grep -q '^Containers="\?no' "$d/stack.conf" || bad="$bad $(basename "${d%/}")"
  done
  check "$name: стеки без compose.yaml объявили Containers=no" "$bad" ""

  # Ни одного заказа базы без включённого поставщика: иначе стек «включается»
  # успешно и падает в рантайме на подключении.
  prefix=$( ROOT_DIR="$m" bash -c ". \"$LIB_DIR/lib-stacks.sh\"; stacks_db_prefix" 2>/dev/null )
  orphan=""
  if [ -z "$prefix" ]; then
    orphan=$(grep -lE '^[A-Za-z]+_(DB|User|Password)=' "$m"/stacks/*/stack.conf 2>/dev/null | wc -l | tr -d ' ')
    [ "$orphan" = "0" ] && orphan=""
  fi
  check "$name: заказов базы без поставщика нет" "$orphan" ""
done

echo "== .gitignore"

# Правило `.env*` без исключения молча съедает каждый новый образец: уже
# добавленные файлы продолжают отслеживаться, а новые не попадают в git, и
# обнаруживается это на свежей машине. Поэтому правила проверяются явно.
ignored() {
  ( cd "$REPO_DIR" && git check-ignore -q "$1" 2>/dev/null && echo ignored || echo tracked )
}

# Секреты и состояние фикстур — мимо git. Настоящих машин здесь нет по
# построению: репозиторий публичный.
for f in tests/machines/alpha/.env \
         tests/machines/alpha/.env-stacks \
         tests/machines/alpha/stacks/site/.env \
         tests/machines/alpha/state/certs/x.crt \
         tests/machines/alpha/.stackyard/platform/bin/stack.sh \
         profiles/stacks/mysql/.env; do
  check "$f игнорируется" "$(ignored "$f")" "ignored"
done

# А образцы — наоборот: без них на сервере не из чего завести файл.
for f in tests/machines/alpha/.env.example \
         tests/machines/alpha/.env-stacks.example \
         tests/machines/alpha/stacks/site/.env.example \
         profiles/stacks/mysql/.env.example \
         platform/getssl-config/getssl.cfg \
         platform/getssl-config/getssl.cfg.template; do
  check "$f НЕ игнорируется" "$(ignored "$f")" "tracked"
done

# Ни одного секрета в общих слоях: они уезжают на КАЖДУЮ машину, и секрет в них
# означает секрет, размноженный по всем клиентам.
leaked=$(find "$REPO_DIR/platform" "$REPO_DIR/profiles" \
              \( -name '.env' -o -name '*.key' -o -name 'account.key' -o -name '*.pem' \) 2>/dev/null | wc -l | tr -d ' ')
check "в platform/ и profiles/ секретов нет" "$leaked" "0"

# Уже отслеживаемый файл, попавший под новое правило, git продолжает
# отслеживать — и правило выглядит работающим, не будучи им.
fell_out=$( cd "$REPO_DIR" && git ls-files | while IFS= read -r f; do
              git check-ignore -q "$f" 2>/dev/null && echo "$f"
            done )
check "отслеживаемые файлы не выпали из git" "$fell_out" ""

echo
if [ "$failures" -eq 0 ]; then
  echo "selftest: всё сошлось"
  exit 0
fi
echo "selftest: провалов: $failures"
exit 1
