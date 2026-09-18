#!/usr/bin/env bash

# Тесты движков платформы на синтетических стеках.
#
#   ./platform/bin/selftest.sh
#
# Существует потому, что проверить генераторы на боевой машине нельзя, не
# сломав её: неверный 10-enabled.conf — это отсутствие всех vhost'ов сразу, а
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
# shellcheck source=platform/lib/lib-stacks.sh
. "$WORK/platform/lib/lib-stacks.sh"
# shellcheck source=platform/lib/lib-env.sh
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

echo "== два корня стеков"

# Главный новый механизм платформы, и до этой секции он не был покрыт ничем.
# Мутационный прогон показал: выключи профильный корень в stack_dir или в
# stacks_available — ни один тест не падал.
#
# Режимы «подключить» и «скопировать» выражены ИМЕННО этими двумя корнями,
# отдельного переключателя нет. Значит ошибка здесь не ломает что-то заметное,
# а делает профильный стек невидимым: его preflight не запускается, его
# stack.conf не читается, его vhost не включается — и всё молча.
fixture_root profile/stacks papa stack.conf 'Requires=""
Domains="papa.test"'
fixture_root profile/stacks papa compose.yaml 'services:
  papa-app:
    image: alpine'
fixture_root profile/stacks papa nginx/50-papa.conf 'server { server_name papa.test; }'
fixture_root profile/stacks quebec stack.conf 'Requires=""'
printf 'Enabled_Stacks="papa quebec alpha"\n' > "$WORK/.env-stacks"

check "профильный стек виден в списке" \
  "$(stacks_available | grep -cx papa)" "1"
check "каталог профильного стека — профильный" \
  "$(stack_dir papa)" "$WORK/profile/stacks/papa"
check "compose профильного стека найден" \
  "$(stack_compose_file papa)" "$WORK/profile/stacks/papa/compose.yaml"
check "домен профильного стека виден" \
  "$(stacks_domains | grep -cx papa.test)" "1"

# .env стека ВСЕГДА машинный, даже у профильного: профиль обновляется целиком,
# и секрет внутри него затёрло бы следующим обновлением.
check ".env профильного стека — в машинном корне" \
  "$(stack_env_file papa)" "$WORK/stacks/papa/.env"

# include обязан указывать в тот корень, где стек лежит на самом деле: иначе
# после копирования стека в машинный nginx продолжал бы читать профильную копию.
check "include профильного стека идёт в профильный каталог" \
  "$(stacks_include_lines | grep -c '/etc/nginx/profile-stacks/papa/nginx')" "1"

# Образец .env ищется РЯДОМ СО СТЕКОМ, а сам .env — в машинном корне. Если
# искать образец по машинному пути, обязательность .env у профильного стека не
# проверяется вовсе, и стек считается укомплектованным без секретов.
fixture_root profile/stacks papa .env.example 'Papa_Secret=CHANGE_ME'
# Стек со своими контейнерами обязан иметь compose.yaml. Молчаливая
# терпимость превращала бы забытый файл в «стек без контейнеров» — рабочий
# конфиг, в котором ничего не запускается.
fixture victor stack.conf 'Requires=""'
check "стек без compose.yaml и без Containers=no — неполон" \
  "$(stack_missing_files victor | grep -c 'compose.yaml')" "1"
fixture whiskey stack.conf 'Requires=""
Containers="no"'
check "с Containers=no претензий нет" "$(stack_missing_files whiskey)" ""

check "профильному стеку нужен .env, раз у него есть образец" \
  "$(stack_missing_files papa)" "stacks/papa/.env"
printf 'x\n' > "$WORK/stacks/papa/.env" 2>/dev/null || { mkdir -p "$WORK/stacks/papa"; printf 'x\n' > "$WORK/stacks/papa/.env"; }
check "с машинным .env претензий нет" "$(stack_missing_files papa)" ""

# Машинный корень перекрывает профильный — это и есть «отцепиться». Объявляет
# стек тот каталог, где лежит stack.conf: половина копии стеком не становится.
mkdir -p "$WORK/stacks/papa"
: > "$WORK/stacks/papa/.env"
check "каталог с одним .env профильный стек НЕ перекрывает" \
  "$(stack_dir papa)" "$WORK/profile/stacks/papa"
fixture papa stack.conf 'Requires=""
Domains="papa.test"'
check "машинная копия перекрывает профильную" \
  "$(stack_dir papa)" "$WORK/stacks/papa"
check "include после копирования идёт в машинный каталог" \
  "$(stacks_include_lines | grep -c '/etc/nginx/stacks/papa/nginx')" "0"
rm -rf "$WORK/stacks/papa"

# Юнит профильного стека обязан указывать в профильный каталог НА СЕРВЕРЕ.
fixture_root profile/stacks papa systemd/devbox-papa-x.service '[Service]
ExecStart=@STACK_DIR@/scripts/x.sh'
check "юнит профильного стека указывает в профиль" \
  "$( DEPLOY_DIR=/srv/m SERVICE_USER=u ONFAILURE= \
      unit_render "$WORK/profile/stacks/papa/systemd/devbox-papa-x.service" papa \
      | grep -c 'ExecStart=/srv/m/profile/stacks/papa/scripts/x.sh' )" "1"

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
check "дубль домена назван двумя разными стеками" \
  "$(check_domains_unique | grep -cE 'is declared by both .* and ' | tr -d ' ')" "1"

# Тот же домен ДВАЖДЫ В ОДНОМ стеке — такая же ошибка, но сообщение «объявлен и
# в hotel, и в hotel» читается как поломка проверки, а не как находка, и её
# перестают читать вместе со всем отчётом.
fixture hotel stack.conf 'Domains="hotel.test hotel.test"
Containers="no"'
printf 'Enabled_Stacks="golf delta hotel"\n' > "$WORK/.env-stacks"
check "дубль внутри одного стека назван своими словами" \
  "$(check_domains_unique | grep -c 'declared twice by stack hotel' | tr -d ' ')" "1"
check "про «и в hotel, и в hotel» не сообщается" \
  "$(check_domains_unique | grep -c 'both hotel and hotel' | tr -d ' ')" "0"
rm -rf "$WORK/stacks/hotel"
printf 'Enabled_Stacks="golf delta"\n' > "$WORK/.env-stacks"
check "домен без vhost и vhost без домена — обе стороны" \
  "$(check_domains_match golf | wc -l | tr -d ' ')" "2"
# CLAUDE.md §7 требует от host-пути обоих свойств сразу: абсолютный И через
# переменную. Проверяются обе половины, поэтому находок здесь две: относительный
# путь и захардкоженный. Путь через переменную и именованный том — не находки.
check "относительный и захардкоженный host-пути найдены, оба вида корректных — нет" \
  "$(check_paths_absolute golf | wc -l | tr -d ' ')" "2"
check "захардкоженный путь назван именно захардкоженным" \
  "$(check_paths_absolute golf | grep -c 'hardcoded host path')" "1"
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

# fastcgi_pass наравне с proxy_pass. Не симметрия ради симметрии: nginx
# резолвит оба при ЧТЕНИИ конфига, и опущенный php-fpm при пересоздании nginx
# уносит все сайты, включая статические. Раньше это ловилось случайно — через
# настоящую фикстуру с PHP-сайтом, — а случайное покрытие исчезает при первой
# же перестановке в тестах.
fixture oscar2 stack.conf 'Requires=""'
fixture oscar2 compose.yaml 'services:
  oscar2-app:
    image: alpine'
fixture oscar2 nginx/80-oscar2.conf 'server {
	location ~ .php$ {
		fastcgi_pass	php-fpm:9000;
	}
}'
printf 'Enabled_Stacks="mike november oscar2"\n' > "$WORK/.env-stacks"
check "fastcgi_pass тоже считается upstream'ом" \
  "$(errexit_run stacks_upstreams | grep -cx 'php-fpm')" "1"
printf 'Enabled_Stacks="mike november"\n' > "$WORK/.env-stacks"
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

# Платформенные сервисы исключаются из сервисов стека: иначе `disable` снёс бы
# контейнер nginx вместе со всеми сайтами машины.
fixture papa2 stack.conf 'Requires=""'
fixture papa2 compose.yaml 'services:
  nginx:
    image: alpine
  papa2-app:
    image: alpine'
check "платформенный сервис не считается сервисом стека" \
  "$(errexit_run stack_services papa2 | grep -cx nginx)" "0"
check "собственный сервис стека считается" \
  "$(errexit_run stack_services papa2 | grep -cx papa2-app)" "1"
check "сервиса, которого не объявляет никто, в списке нет" \
  "$(printf '%s\n' "$known" | grep -cx 'stray-app')" "0"

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
# Путь в S3 для SQLite — формула, которую делят backup.sh и check-backups.sh.
# Проверяется ЗНАЧЕНИЕ, а не только «формула одна»: разъехавшись, они молча
# кладут и ищут в разных местах.
check "путь SQLite в S3" "$(sqlite_s3_subpath /var/lib/app/twd-tm.db)" "sqlite/twd-tm"
check "путь SQLite: расширение .db срезано" "$(sqlite_s3_subpath /x/base.db)" "sqlite/base"

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

echo "== гигиена платформы"

# Классы дефектов, на которых я уже попадался. Проверяем не конкретные места, а
# сам класс: конкретное чинится один раз, класс возвращается.
#
# Везде -I: без него любой бинарный файл, случайно оказавшийся в дереве
# (например, .swp от открытого редактора), даёт строку «Binary file ... matches»
# и роняет сразу несколько гардов — то есть тесты падают из-за постороннего
# файла, а не из-за кода.

# 1. Путь к стеку, собранный строкой, слеп к профильному корню: такой стек
#    просто не находится, и его preflight/health/stack.conf молча не читаются.
#    Единственный законный способ — stack_dir и производные от него.
#
#    Ищем сам ПРИЗНАК — литерал '/stacks/' сразу перед подстановкой, — а не
#    конкретные имена переменных: прошлая версия проверки перечисляла ROOT_DIR
#    и stacks_root, из-за чего не видела ни $root, ни ${DEPLOY_DIR:?}, ни один
#    файл в profiles/. Она давала ноль совпадений при шести настоящих случаях,
#    то есть служила разрешением не думать про класс.
#
#    Законные исключения помечаются в коде комментарием # stack-path-ok:
#    их два вида — определение самих корней и .env стека, который по замыслу
#    ВСЕГДА машинный. Пометка грепается, то есть исключение видно и его можно
#    пересчитать; молчаливого исключения быть не должно.
built=$(grep -rInE '/stacks/\$' \
          "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib "$REPO_DIR"/bin \
          "$REPO_DIR"/profiles 2>/dev/null \
        | grep -v 'stack-path-ok' \
        | grep -vE '(selftest|mutate)\.sh:' || true)
check "путь к стеку нигде не собирается строкой" "$built" ""

# 2. Запись в platform/ или profile/: это общие слои, bootstrap перезаписывает
#    их целиком. Записанное туда исчезает при следующем обновлении, а до того
#    лежит в слое, который раздаётся всем машинам.
#    Ищем любую запись, а не только `>`: cp, tee и >> туда же. И смотрим все
#    каталоги, где может оказаться пишущий код, а не только два.
writes=$(grep -rInE '(>>?|tee|cp|mkdir -p|install) +[^|#]*\$\{?(ROOT_DIR|REPO_DIR|Platform_Deploy_Dir)[^ "]*/(platform|profile)/' \
           "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib "$REPO_DIR"/bin \
           "$REPO_DIR"/profiles 2>/dev/null \
        | grep -v 'stack-path-ok' | grep -vE '(selftest|mutate)\.sh:' || true)
check "в общие слои никто не пишет" "$writes" ""

# 3. `sudo -u` обязан пробрасывать ROOT_DIR через env: sudo сбрасывает
#    окружение, и скрипт платформы вычислит корень от своего пути — а лежит он
#    в .stackyard/platform/bin, то есть корнем станет .stackyard. Отказ
#    выглядит как «нет .env» на машине, где .env есть.
badsudo=$(grep -rIn 'sudo -u' "$REPO_DIR"/platform/bin "$REPO_DIR"/bin 2>/dev/null \
          | grep -vE ':[0-9]+:[[:space:]]*#' \
          | grep -vE '(selftest|mutate)\.sh:' \
          | grep -v 'env ROOT_DIR=' || true)
check "sudo -u пробрасывает ROOT_DIR" "$badsudo" ""

# 3. Менеджер пакетов и команды дистрибутива не зашиваются: платформа
#    раздаётся, и `dnf` в ней означает, что на Debian/Ubuntu установка упирается
#    в «dnf: command not found» — с подсказкой, которую невозможно выполнить.
#    Ровно это и случилось на первом же реальном сервере.
#
#    Сама абстракция (она обязана перечислить менеджеры) помечена в коде
#    # pkg-mgr-ok — как и другие законные исключения: пометка грепается, то
#    есть исключение видно и его можно пересчитать.
hardpm=$(grep -rInE '(^|[^_[:alnum:]])(dnf|yum|apt-get|apk add|zypper) ' \
           "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib "$REPO_DIR"/bin 2>/dev/null \
         | grep -vE ':[0-9]+:[[:space:]]*#' \
         | grep -v 'pkg-mgr-ok' || true)
check "команды менеджера пакетов не зашиты" "$hardpm" ""

# 3. Директива `# shellcheck source=` обязана резолвиться ОТ КОРНЯ репозитория:
#    именно так шеллчек её и ищет — от рабочего каталога, а не от проверяемого
#    файла. Форма ../lib/... выглядела верной и молча не резолвилась, а SC1091
#    идёт уровнем info, то есть при -S error его не видно вовсе. Итог: -x был
#    включён, а каждый скрипт линтился в изоляции, и опечатка в пути к
#    библиотеке доживала до рантайма (ровно так уцелел дефект A9).
badsrc=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  t="${line##*source=}"; t="${t%% *}"
  [ -f "$REPO_DIR/$t" ] || badsrc="$badsrc ${line%%:*}:$t"
#    Ищем НАСТОЯЩУЮ форму директивы (строка целиком — комментарий шеллчека), а
#    не подстроку: иначе проверка ловит собственный образец поиска и рассказ о
#    том, что она проверяет. На этом я попался трижды подряд.
done < <(grep -rInE '^[[:space:]]*# shellcheck source=' "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib \
           "$REPO_DIR"/bin "$REPO_DIR"/tests "$REPO_DIR"/profiles 2>/dev/null)
check "директивы shellcheck source= резолвятся" "$badsrc" ""

# 3. Ссылка на платформенный compose-файл, которого нет. Так в stack.sh жил
#    `-f platform/compose/php-fpm.yaml`, оставшийся с тех пор, когда php-fpm был
#    платформенным: compose падал на несуществующем -f, 2>/dev/null это съедал,
#    и целый блок проверки был мёртв на всех машинах.
#    Строки-комментарии пропускаем: guard про КОД, а не про прозу. Объяснение
#    прошлого дефекта неизбежно содержит имя файла, которого больше нет, и
#    ловить его — значит заставлять стирать объяснения.
badref=""
for ref in $(grep -rIhE 'platform/compose/[A-Za-z0-9_.-]+\.yaml' \
               "$REPO_DIR"/platform/bin "$REPO_DIR"/bin 2>/dev/null \
             | grep -vE '^[[:space:]]*#' \
             | grep -oE 'platform/compose/[A-Za-z0-9_.-]+\.yaml' | sort -u); do
  case "$ref" in *.generated.yaml) continue ;; esac
  [ -f "$REPO_DIR/$ref" ] || badref="$badref $ref"
done
check "ссылок на несуществующие файлы платформы нет" "$badref" ""

# 4. Скрипты стеков подключают библиотеки по пути platform/lib/. Путь из
#    devbox6 (scripts/lib-env.sh) переживал перенос незамеченным, потому что
#    его следствие выглядело как «стек не отвечает», а не как сломанный скрипт.
badlib=$(grep -rIn 'ROOT_DIR[^"]*}\?/scripts/lib-' "$REPO_DIR"/profiles "$REPO_DIR"/platform 2>/dev/null \
         | grep -vE ':[0-9]+:[[:space:]]*#' || true)
check "стеки подключают библиотеки из platform/lib" "$badlib" ""

# 3. Имя конкретной машины или клиента в публичном слое. Репозиторий публичный;
#    кроме утечки это ещё и проверка, которая на другой машине молча проходит.
names=$(grep -rniE 'devbox6|devbox-asstnt|12devs|my-new-site|pankov\.me|filinn|pckup|sanya|quotrum|tokensale' \
          "$REPO_DIR"/platform "$REPO_DIR"/profiles "$REPO_DIR"/bin 2>/dev/null \
        | grep -v '^Binary' | grep -v 'selftest\.sh:[0-9]*:names=' \
        | grep -vE ':[0-9]+:[[:space:]]*#' || true)
check "имён машин и клиентов в платформе нет" "$names" ""

# 5. Команда, которой на чужой машине может не быть, либо ведущая себя там
#    иначе. Пять отказов подряд на первом реальном сервере были именно такими,
#    и ни один не поймали тесты: у меня всё стояло. Поэтому ловим класс —
#    прямой вызов в обход обёртки из lib-env.sh, — а не конкретный вызов.
#    Законное место обёрток одно, оно помечено # portable-ok.

#    5a. shasum/sha256sum. Отсутствие первого давало ПУСТУЮ сумму, она не
#        совпадала ни с чем, и check-vendor докладывал, что на месте правили
#        каждый файл платформы: отсутствие инструмента выглядело как диверсия.
badsha=$(grep -rInE '(^|[^_[:alnum:]])(shasum|sha256sum)[[:space:]]' \
           "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib "$REPO_DIR"/bin "$REPO_DIR"/tests 2>/dev/null \
         | grep -vE ':[0-9]+:[[:space:]]*#' \
         | grep -vE '(selftest|mutate)\.sh:' | grep -v 'portable-ok' || true)
check "суммы считаются через sha256_file" "$badsha" ""

#    5b. timeout — из GNU coreutils, в macOS и BSD его нет вовсе. Без него
#        сторож просто не запускается, и --check зависает ровно там, где
#        сторож и был нужен: на неотвечающем health.sh.
badto=$(grep -rInE '(^|[^_[:alnum:]-])timeout[[:space:]]+"?\$' \
          "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib "$REPO_DIR"/bin 2>/dev/null \
        | grep -vE ':[0-9]+:[[:space:]]*#' \
        | grep -vE '(selftest|mutate)\.sh:' | grep -v 'portable-ok' || true)
check "сторож времени идёт через run_with_timeout" "$badto" ""

#    5c. `find -printf` — расширение GNU; BSD find на нём падает целиком.
#        Вызов был обёрнут в 2>/dev/null || true, поэтому падал молча: счётчик
#        выше говорил «невыгруженных дампов N», а список под ним был пуст.
badfp=$(grep -rIn -- '-printf' "$REPO_DIR"/platform "$REPO_DIR"/bin "$REPO_DIR"/tests 2>/dev/null \
        | grep -v 'platform/getssl' | grep -vE '(selftest|mutate)\.sh:' \
        | grep -vE ':[0-9]+:[[:space:]]*#' || true)
check "find -printf (только GNU) не используется" "$badfp" ""

#    5d. `date -j -f` без -u и без %z в формате разбирает строку как ЛОКАЛЬНОЕ
#        время. Метки S3 приходят в UTC, поэтому к востоку от Гринвича свежий
#        бэкап выглядел устаревшим, а к западу — устаревший проходил проверку.
#        Второе хуже: проверка свежести бэкапов, которая молча одобряет старый.
badtz=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in *'%z'*|*'date -j -u'*|*'%Z'*) continue ;; esac
  badtz="$badtz${line%%:*} "
done < <(grep -rIn 'date -j' "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib "$REPO_DIR"/bin 2>/dev/null \
         | grep -v 'platform/getssl' | grep -vE '(selftest|mutate)\.sh:' \
         | grep -vE ':[0-9]+:[[:space:]]*#')
check "разбор времени BSD-датой не считает UTC локальным" "$badtz" ""

# 6. `declare -gA` — это bash >= 4.2, а штатный /bin/bash в macOS остался 3.2.
#    Без явной проверки версии библиотека молча загружалась с пустым ENV_VARS:
#    каждый env_get возвращал умолчание, и скрипт делал не то, о чём просили.
#    Попасть на 3.2 легче всего через sudo — он чистит PATH.
badbv=""
for f in $(grep -rIl 'declare -gA' "$REPO_DIR"/platform/lib 2>/dev/null); do
  grep -q 'BASH_VERSINFO' "$f" || badbv="$badbv $f"
done
check "declare -gA прикрыт проверкой версии bash" "$badbv" ""

# 7. Разбор аргументов: `WANT="$2"; shift 2` под set -u на забытом значении
#    даёт «$2: unbound variable» — сообщение про внутренности скрипта вместо
#    сообщения про то, чего не хватает в командной строке.
badsh=$(grep -rIn 'shift 2' "$REPO_DIR"/bin "$REPO_DIR"/platform/bin 2>/dev/null \
        | grep -vE ':[0-9]+:[[:space:]]*#' \
        | grep -vE '(selftest|mutate)\.sh:' | grep -v '${2-}' || true)
check "необязательный аргумент читается как \${2-}" "$badsh" ""

# 8. Поиск дубликатов через `prev` в awk обязан требовать, чтобы вторая строка
#    была от ДРУГОЙ машины. Один и тот же ключ у одной машины лежит сразу в
#    двух файлах (Mysql_Root_Password в .env и в stacks/mysql/.env), и без
#    этого условия аудит изоляции докладывал «ключ одинаков у машин X и X».
#    Ложная тревога в проверке безопасности хуже её отсутствия: её учатся не
#    читать, а вместе с ней перестают читать и настоящую находку.
#    Смотрим не на строку и не на файл, а на ОКНО вокруг каждого сравнения.
#    Построчно нельзя: сравнение источников стоит строкой ниже, внутри того же
#    awk-выражения. По файлу целиком — тоже: в audit-isolation.sh таких awk два,
#    и исправленный прикрывал собой сломанный (ровно так эта проверка и
#    пропустила первую мутацию).
baddup=""
while IFS=: read -r f n _; do
  [ -n "${n:-}" ] || continue
  sed -n "$((n > 2 ? n - 2 : 1)),$((n + 5))p" "$f" | grep -qE '\$2 (==|!=) prev' \
    || baddup="$baddup $f:$n"
done < <(grep -rIn '$1 == prev' "$REPO_DIR"/bin "$REPO_DIR"/platform 2>/dev/null \
         | grep -vE '(selftest|mutate)\.sh:')
check "поиск дубликатов отличает источник от самого себя" "$baddup" ""

# 9. Чужой код копией в репозитории. Копия getssl весила 155 КБ, лежала под
#    GPL-3 в публичном репозитории под MIT и успела обрасти локальными
#    правками, про которые никто уже не помнил, откуда они. Теперь такие вещи
#    закрепляются lock-файлом и скачиваются на машину; проверяем, что копия не
#    вернулась и что ссылки на неё не остались.
#
#    Признак копии — исполняемый файл вне bin/ и lib/ длиннее 500 строк:
#    маленькие шаблоны и конфиги так не выглядят.
vendored=""
while IFS= read -r f; do
  case "$f" in */bin/*|*/lib/*) continue ;; esac
  [ -x "$f" ] || continue
  [ "$(wc -l < "$f")" -gt 500 ] && vendored="$vendored $f"
done < <(find "$REPO_DIR/platform" "$REPO_DIR/profiles" -type f 2>/dev/null)
check "чужой код не лежит копией в платформе" "$vendored" ""

#    Хвост ([^-.a-zA-Z0-9]|$) обязателен с обеих сторон: без «|$» шаблон не
#    видел ссылку в КОНЦЕ строки — а именно так она и выглядит в ExecStart.
stale=$(grep -rInE 'platform/getssl([^-.a-zA-Z0-9]|$)' "$REPO_DIR"/platform "$REPO_DIR"/bin "$REPO_DIR"/templates 2>/dev/null \
        | grep -vE '(selftest|mutate)\.sh:' | grep -vE ':[0-9]+:[[:space:]]*#' || true)
check "ссылок на убранную копию getssl не осталось" "$stale" ""

# 10. Корень машины, вычисленный от пути скрипта. На машине platform/ — это
#     симлинк в .stackyard/, и `cd -P` его разворачивает: два уровня вверх дают
#     .stackyard, а не машину. Скрипт после этого заводит state/ внутри слоя,
#     который перезаписывается при каждом ./bootstrap. Замечено на живом
#     сервере: htpasswd.sh положил файл в .stackyard/state/ и там же его искал,
#     так что «пусто» он печатал совершенно честно.
badroot=""
for f in $(grep -rIl 'cd "$DIR0/../\.\." && pwd' "$REPO_DIR"/platform/bin 2>/dev/null); do
  grep -q '\.stackyard' "$f" || badroot="$badroot $f"
done
check "ROOT_DIR не остаётся внутри .stackyard" "$badroot" ""

# 11. Взаимоисключающие флаги htpasswd. -i читает пароль со стдина, -b берёт его
#     ТРЕТЬИМ аргументом; вместе они означают «жду третий аргумент», которого
#     нет, и htpasswd печатает usage и выходит. На сервере это выглядит как
#     сломанный скрипт, а не как неверные флаги. Прогоном не проверить: htpasswd
#     живёт в контейнере, а selftest работает без docker.
badflags=$(grep -n 'FLAGS=' "$REPO_DIR/platform/bin/htpasswd.sh" 2>/dev/null \
           | grep -E '\-[a-zA-Z]*i[a-zA-Z]*b|\-[a-zA-Z]*b[a-zA-Z]*i' || true)
check "htpasswd: -i и -b не стоят вместе" "$badflags" ""

# 12. Обёртки машины перечислены одним списком (templates/machine/wrappers), и
#     каждая цель обязана существовать: опечатка здесь даёт машине точку входа,
#     которая падает на "Платформы нет" — то есть сообщением про bootstrap,
#     хотя bootstrap ни при чём.
badwrap=""
while IFS=: read -r name target; do
  case "$name" in ''|\#*) continue ;; esac
  [ -f "$REPO_DIR/platform/bin/$target" ] || badwrap="$badwrap $name->$target"
done < "$REPO_DIR/templates/machine/wrappers"
check "цели обёрток машины существуют" "$badwrap" ""

# 13. Одна функция, определённая дважды. В bash побеждает ПОСЛЕДНЕЕ
#     определение, а первое остаётся мёртвым кодом, который выглядит живым:
#     правку в нём вносят, тестируют — и ничего не меняется. Хуже, если копии
#     разошлись: тогда перестановка блоков местами молча возвращает старое
#     поведение.
dupfn=""
while IFS= read -r f; do
  while IFS= read -r fn; do
    [ "$(grep -cE "^${fn}\(\) \{" "$f")" -gt 1 ] && dupfn="$dupfn $(basename "$f"):$fn"
  done < <(grep -oE '^[a-z_][a-z_0-9]*\(\) \{' "$f" | sed 's/() {//' | sort -u)
done < <(find "$REPO_DIR/platform/lib" "$REPO_DIR/platform/bin" "$REPO_DIR/bin" -name '*.sh' 2>/dev/null)
check "ни одна функция не определена дважды" "$dupfn" ""

# 13. Имя образа nginx — одно на всех, кто его называет. Копий было три, и
#     htpasswd.sh про Platform_Nginx_Image вовсе не знал: на машине с
#     переопределённым образом файл паролей готовил НЕ тот nginx, который его
#     читает, — а от образа зависит gid, то есть права на файл.
#     В compose литерал неизбежен (там подстановки без запасного значения нет),
#     поэтому его и не считаем; речь про скрипты.
badimg=$(grep -rInE 'nginx:[0-9]+\.[0-9]+' "$REPO_DIR"/platform/bin "$REPO_DIR"/bin 2>/dev/null \
         | grep -vE '(selftest|mutate)\.sh:' | grep -vE ':[0-9]+:[[:space:]]*#' || true)
check "скрипты берут образ nginx из nginx_image" "$badimg" ""

# 14. Файл, созданный контейнером, принадлежит root: на хосте его уже не
#     переназначить, и `chmod` от обычного пользователя падает с EPERM. Права
#     должен ставить сам контейнер, пока он root. Проверяем, что после docker
#     run в скрипте не осталось хостового chmod по этому файлу.
badchmod=$(grep -n '^chmod .*"\$FILE"' "$REPO_DIR/platform/bin/htpasswd.sh" 2>/dev/null || true)
check "права файла паролей ставит контейнер, а не хост" "$badchmod" ""

# Lock обязан называть всё, без чего скачивание не воспроизводится. Пустое поле
# здесь означало бы «скачаем что дадут»: ровно то, от чего lock и заводят.
for field in repo version sha256; do
  v=$(sed -n "s/^$field=//p" "$REPO_DIR/platform/getssl.lock" | head -n 1)
  check "getssl.lock: поле $field заполнено" "$([ -n "$v" ] && echo да || echo нет)" "да"
done
# Сумма — ровно 64 шестнадцатеричных знака. Обрезанная или с пробелом не
# совпадёт ни с чем, и getssl-fetch будет вечно докладывать о подмене.
check "getssl.lock: сумма похожа на sha256" \
  "$(sed -n 's/^sha256=//p' "$REPO_DIR/platform/getssl.lock" | head -n 1 | grep -cE '^[0-9a-f]{64}$')" "1"

echo "== порядок и зоны лимитов"

# Файлы conf.d читаются по алфавиту, а nginx разрешает имя зоны в момент
# разбора server-блока. Генерируемый файл, попавший ПЕРЕД определениями зон,
# означает "unknown limit_req_zone" и отказ старта — то есть краш-луп по
# restart: always. На машине разработчика nginx не запускается вовсе, поэтому
# заметить это можно только так.
inc_name="$(basename "$(stacks_include_file)")"
first=$( { printf '%s\n' "$inc_name"
           ls -1 "$REPO_DIR"/platform/nginx-vhosts/*.conf 2>/dev/null | sed 's:.*/::'; } | sort | head -n 1)
check "определения зон читаются раньше vhost'ов стеков" \
  "$([ "$first" = "$inc_name" ] && echo "СНАЧАЛА vhost'ы" || echo ok)" "ok"

# Платформа несёт только общие зоны. Политика конкретной машины — какой URI
# считать логином — уехав в общий слой, попала бы на все машины сразу.
# Комментарии пропускаем — как и в остальных гигиенических проверках:
# объяснение прошлого дефекта неизбежно содержит то, что он ловит.
check "в платформенных зонах нет машинной политики" \
  "$(grep -vE '^[[:space:]]*#' "$REPO_DIR"/platform/nginx-vhosts/00-limits.conf \
     | grep -cE 'map |user/login' || true)" "0"

# Совместимость образа с директивами платформы.
ENV_VARS=(); ENV_VARS[Platform_Nginx_Image]='nginx:1.19-alpine'
check "старый образ nginx назван" "$(check_nginx_image | grep -c 'старее 1.25.1')" "1"
ENV_VARS[Platform_Nginx_Image]='nginx:1.25.1-alpine'
check "1.25.1 претензий не вызывает" "$(check_nginx_image)" ""
ENV_VARS=()

echo "== include: генератор против читателя"

# Формула строки include пишется в одном месте и читается в другом. Разъезд
# молчит в обе стороны: прошлая версия читателя искала "conf.d/<стек>/*.conf",
# которой генератор не производил никогда, и колонка VHOSTS показывала «выкл»
# у каждого стека с vhost'ами. Колонка, которая всегда врёт, хуже отсутствующей.
fixture tango stack.conf 'Domains="tango.test"
Containers="no"'
fixture tango nginx/70-tango.conf 'server { server_name tango.test; }'
fixture_root profile/stacks uniform stack.conf 'Domains="uniform.test"
Containers="no"'
fixture_root profile/stacks uniform nginx/71-uniform.conf 'server { server_name uniform.test; }'
printf 'Enabled_Stacks="papa lima november tango uniform"\n' > "$WORK/.env-stacks"

mkdir -p "$(dirname "$(stacks_include_file)")"
stacks_include_content > "$(stacks_include_file)"

check "читатель видит включённый машинный стек" \
  "$(stack_vhost_enabled tango && echo да || echo нет)" "да"
check "читатель видит включённый ПРОФИЛЬНЫЙ стек" \
  "$(stack_vhost_enabled uniform && echo да || echo нет)" "да"

printf 'Enabled_Stacks="papa lima november"\n' > "$WORK/.env-stacks"
stacks_include_content > "$(stacks_include_file)"
check "выключенный стек читателем не виден" \
  "$(stack_vhost_enabled tango && echo да || echo нет)" "нет"

echo "== состояние свежей машины"

# На свежей машине после ./bootstrap каталога state/ нет вовсе: bootstrap несёт
# платформу, а состояние — дело машины. Первая же команда писала в
# state/nginx-vhosts/ и умирала сырой ошибкой оболочки, а databases.yaml не
# создавался никогда — при том что --check требовал `sync`, который его и не
# создаёт. Замкнутый круг на первой минуте знакомства с платформой.
rm -rf "$WORK/state"
printf 'Enabled_Stacks="papa lima"\n' > "$WORK/.env-stacks"
ensure_state_dirs
for d in nginx-vhosts certs htpasswd getssl-config; do
  check "state/$d заведён" "$([ -d "$WORK/state/$d" ] && echo да || echo нет)" "да"
done
check "каталог поставщика заведён" "$([ -d "$WORK/state/papa" ] && echo да || echo нет)" "да"

# А на машине без поставщика его каталога быть не должно: пустой state/papa
# там вводит в заблуждение не меньше, чем его отсутствие там, где он нужен.
rm -rf "$WORK/state"
printf 'Enabled_Stacks="lima"\n' > "$WORK/.env-stacks"
ensure_state_dirs
check "без поставщика его каталог не заводится" \
  "$([ -d "$WORK/state/papa" ] && echo да || echo нет)" "нет"
check "без поставщика путь к файлу баз пуст" "$(stacks_databases_file)" ""
printf 'Enabled_Stacks="papa lima november"\n' > "$WORK/.env-stacks"

# Заглушки сертификатов обязаны заводиться и профильным стекам. Иначе домен
# объявлен, конфиг getssl есть, а файла нет — nginx не стартует и с
# restart: always уносит ВСЕ сайты машины.
fixture_root profile/stacks sierra stack.conf 'Domains="sierra.test"
Containers="no"'
fixture_root profile/stacks sierra nginx/60-sierra.conf 'server {
	ssl_certificate /etc/nginx/certs/sierra.test-fullchain.crt;
	ssl_certificate_key /etc/nginx/certs/sierra.test.key;
}'
printf 'Enabled_Stacks="papa lima november sierra"\n' > "$WORK/.env-stacks"
check "путь сертификата профильного стека виден" \
  "$(stacks_cert_paths | grep -c 'sierra.test-fullchain.crt')" "1"
printf 'Enabled_Stacks="papa lima november"\n' > "$WORK/.env-stacks"

echo "== посторонний каталог среди vhost'ов"

# Docker, не найдя файла для bind-mount, заводит на его месте КАТАЛОГ от root.
# Он попадает под маску *.conf, по которой nginx читает включённые vhost'ы, и
# роняет его: «pread() ... failed (21: Is a directory)». С restart: always это
# краш-луп, уносящий все сайты, а сообщение говорит про pread — то есть отказ
# выглядит как поломка nginx, а не как мусор в каталоге.
#
# Пережить обновление платформы он может: state/ машинный, bootstrap его не
# трогает. Так и случилось — каталог от прежней спеки дождался версии, где
# маска стала его читать.
vh="$WORK/state/nginx-vhosts"
mkdir -p "$vh"
: > "$vh/10-enabled.conf"
check "нормальный каталог vhost'ов претензий не вызывает" "$(check_vhost_dir "$vh")" ""

mkdir -p "$vh/00-enabled.conf"
check "посторонний каталог найден" \
  "$(check_vhost_dir "$vh" | wc -l | tr -d ' ')" "1"
check "в сообщении есть выполнимая команда с sudo" \
  "$(check_vhost_dir "$vh" | grep -c 'sudo rm -rf')" "1"
rmdir "$vh/00-enabled.conf"

check "несуществующий каталог — не находка" "$(check_vhost_dir "$WORK/нет-такого")" ""

# Функция проверена выше, но она бесполезна, если её не зовут. Мест ровно два:
# перед записью в каталог (иначе nginx -t падает, и причина тонет в откате) и
# в --check (иначе про мусор узнают от краш-лупа).
check "проверка каталога вызывается и при записи, и при --check" \
  "$(grep -c 'check_vhost_dir "\$(dirname' "$REPO_DIR/platform/bin/stack.sh")" "2"

echo "== вложенные монтирования"

# Точку монтирования для вложенного пути docker создаёт ВНУТРИ уже
# смонтированного каталога. Если тот смонтирован с :ro, создать её нечем, и
# контейнер не стартует вовсе. Сообщение при этом говорит про mountpoint и
# read-only file system — то есть отказ выглядит как поломка docker, а не как
# неверная спека, и ищут его не там. Так стоял генерируемый список include'ов:
# файлом внутрь conf.d, смонтированного с :ro.
#
# Проверяем КЛАСС: ни одна цель монтирования не должна лежать внутри другой
# цели, смонтированной только на чтение. Разбираем все compose-файлы платформы,
# а не один nginx.yaml: следующий такой же появится в другом.
nested=""
while IFS= read -r f; do
  # Из строки-элемента volumes берём ЦЕЛЬ и режим: "<цель> <ro|rw>".
  #
  # Источник отрезаем по ПОСЛЕДНЕМУ ":/", а не по первому двоеточию: в
  # источнике стоит ${Platform_Deploy_Dir:?}, и двоеточие внутри подстановки
  # съедало половину строки. На этом гард сначала и промолчал.
  mounts=$(grep -oE '^[[:space:]]*-[[:space:]]+[^[:space:]]+:/[^[:space:]]+' "$f" \
           | sed -E 's|.*:(/[^:]+)(:([a-z]+))?$|\1 \2|; s/:ro$/ ro/; s/ $/ rw/' \
           | sed -E 's/ :ro$/ ro/; s/  +/ /')
  while IFS=' ' read -r ro_dst mode; do
    [ "${mode:-}" = ro ] || continue
    while IFS=' ' read -r o_dst _; do
      [ -n "${o_dst:-}" ] || continue
      case "$o_dst" in
        "$ro_dst"/*) nested="$nested $(basename "$f"):$o_dst-внутри-$ro_dst" ;;
      esac
    done <<< "$mounts"
  done <<< "$mounts"
done < <(find "$REPO_DIR/platform/compose" "$REPO_DIR/profiles" -name '*.yaml' 2>/dev/null)
check "внутрь :ro-каталога ничего не монтируется" "$nested" ""

echo "== генерируемые файлы: имя одно на всех"

# Переименование генерируемого файла обязано доходить до ВСЕХ, кто его
# называет. Фикс A15 переименовал 00-enabled.conf в 10-enabled.conf в
# генераторе — и не дошёл до compose, который монтирует его по имени, и до
# docker-compose.sh, где ветка case сверялась с образцом имени.
#
# Обошлось это дорого: docker на отсутствующий файл в bind-mount заводит
# КАТАЛОГ, после чего nginx не стартует вовсе — «create mountpoint ...
# read-only file system». То есть отказ выглядит как поломка docker, а не как
# незавершённое переименование.
#
# В compose литерал неизбежен: подстановок с вызовом функции там нет. Поэтому
# сверяем литерал с тем, что производит библиотека.
# Каталог, куда пишется генерируемый include, обязан быть смонтирован целиком.
inc_dir="$(basename "$(dirname "$(stacks_include_file)")")"
check "compose монтирует каталог генерируемых vhost'ов" \
  "$(grep -cE "state/$inc_dir:/etc/nginx/[a-z-]+:ro" "$REPO_DIR/platform/compose/nginx.yaml")" "1"

# И читается он ровно одной строкой из платформенного файла conf.d. Имя этого
# файла задаёт порядок: зоны лимитов обязаны быть объявлены до server-блоков.
inc_mount="$(grep -oE "state/$inc_dir:/etc/nginx/[a-z-]+:ro" "$REPO_DIR/platform/compose/nginx.yaml" | head -n 1)"
inc_mount="${inc_mount#*:}"; inc_mount="${inc_mount%:ro}"
check "платформа читает этот каталог одной строкой include" \
  "$(grep -rlF "include $inc_mount/" "$REPO_DIR"/platform/nginx-vhosts/*.conf 2>/dev/null | wc -l | tr -d ' ')" "1"
# Обе стороны обязаны найтись. Пустое имя сравнивается как меньшее любого, то
# есть исчезнувший файл зон выглядел бы как правильный порядок — проверка
# одобрила бы ровно то, ради чего написана.
reader=$(grep -rlF "include $inc_mount/" "$REPO_DIR"/platform/nginx-vhosts/*.conf 2>/dev/null | head -n 1)
limits=$(grep -rlE '^[[:space:]]*limit_req_zone' "$REPO_DIR"/platform/nginx-vhosts/*.conf 2>/dev/null | head -n 1)
check "зоны лимитов и читатель — оба на месте" \
  "$([ -n "$reader" ] && [ -n "$limits" ] && echo да || echo нет)" "да"
check "читатель сортируется ПОСЛЕ зон лимитов" \
  "$([ -n "$reader" ] && [ -n "$limits" ] && [ "$(basename "$limits")" \< "$(basename "$reader")" ] && echo да || echo нет)" "да"

# Имя генерируемого compose-файла в коде не пишется вовсе — спрашивается у
# stacks_static_file. Комментарии не в счёт: гард про код, а объяснение
# прошлого дефекта неизбежно называет файл.
stat_name="$(basename "$(stacks_static_file)")"
# grep по ОДНОМУ файлу не печатает его имя, поэтому строка начинается сразу с
# номера — шаблон исключения комментариев здесь другой, чем у гардов выше.
badstat=$(grep -In "$stat_name" "$REPO_DIR/platform/bin/docker-compose.sh" 2>/dev/null \
          | grep -vE '^[0-9]+:[[:space:]]*#' || true)
check "имя генерируемого compose-файла в коде не повторяется" "$badstat" ""

# Ни один потребитель не должен узнавать имя по образцу: образец переживает
# переименование молча, а ветка case перестаёт совпадать без единого слова.
badpat=$(grep -rInE '\*[0-9]+-enabled\.conf\)' "$REPO_DIR"/platform/bin "$REPO_DIR"/bin 2>/dev/null \
         | grep -vE '(selftest|mutate)\.sh:' | grep -vE ':[0-9]+:[[:space:]]*#' || true)
check "имя генерируемого файла не сверяется образцом" "$badpat" ""

echo "== устаревший bind-mount"

# ./bootstrap заменяет .stackyard целиком (rm -rf), а platform/ — симлинк туда.
# Контейнер, запущенный до этого, остаётся с монтированием на УДАЛЁННЫЙ
# каталог: путь в docker inspect прежний, файлов по нему ноль. Сверка путей
# такое пропускает — она сравнивает строки, а изменился inode.
#
# Саму сверку selftest прогнать не может (нужен docker), поэтому проверяется
# ПРАВИЛО. Пустой каталог на хосте не улика: смонтировать пустое законно, и
# [FAIL] на этом был бы вечной ложной тревогой на свежей машине.
check "непустой на хосте против пустого в контейнере — улика" \
  "$(mount_looks_stale 5 0 && echo да || echo нет)" "да"
check "совпадающие количества — не улика" \
  "$(mount_looks_stale 5 5 && echo да || echo нет)" "нет"
check "пусто с обеих сторон — не улика" \
  "$(mount_looks_stale 0 0 && echo да || echo нет)" "нет"
check "пусто на хосте, непусто в контейнере — не улика" \
  "$(mount_looks_stale 0 5 && echo да || echo нет)" "нет"
check "пустые аргументы не считаются уликой" \
  "$(mount_looks_stale "" "" && echo да || echo нет)" "нет"

echo "== корень машины из-под симлинка"

# Раскладка ровно как на машине: platform — симлинк в .stackyard/. Гард выше
# смотрит на текст скрипта, а этот блок — на то, КУДА скрипт на самом деле
# сходит. Текстовая проверка одна не годится: она пройдёт и на скрипте, где
# нужная строка есть, но стоит не в той ветке.
MROOT="$WORK/машина"
rm -rf "$MROOT"
mkdir -p "$MROOT/.stackyard"
cp -R "$REPO_DIR/platform" "$MROOT/.stackyard/platform"
ln -s .stackyard/platform "$MROOT/platform"
# pwd -P у ожидания — потому что скрипт разворачивает симлинки сам (cd -P), а
# в macOS $TMPDIR это /var -> /private/var. Иначе тест ловил бы раскладку
# временного каталога, а не то, ради чего написан.
MREAL="$(cd "$MROOT" && pwd -P)"
check "скрипт через симлинк видит корнем машину, а не .stackyard" \
  "$(cd "$MROOT" && env -u ROOT_DIR ./platform/bin/htpasswd.sh proba --list 2>&1)" \
  "пусто: $MREAL/state/htpasswd/proba"
rm -rf "$MROOT"

echo "== переносимость: время, суммы, сторож"

# Метка S3 разбирается в ОДНО И ТО ЖЕ независимо от часового пояса машины, на
# которой запущена проверка. Иначе check-backups.sh считает возраст бэкапа со
# сдвигом на величину пояса: к востоку от Гринвича свежий дамп выглядит
# устаревшим (ложная тревога), к западу — устаревший проходит проверку.
# Второе тише и потому хуже.
#
# Гоняем в трёх поясах намеренно: в UTC неверный разбор даёт верный ответ, то
# есть тест, написанный только под UTC, был бы вечнозелёным.
for tz in UTC Asia/Tokyo America/New_York; do
  for form in '2026-01-02T03:04:05+00:00' '2026-01-02T03:04:05Z' \
              '2026-01-02T03:04:05.123456+00:00' '2026-01-02T06:04:05+03:00'; do
    check "iso_to_epoch $form в TZ=$tz" "$(TZ="$tz" iso_to_epoch "$form")" "1767323045"
  done
done
check "iso_to_epoch без смещения считает UTC" "$(TZ=Asia/Tokyo iso_to_epoch '2026-01-02T03:04:05')" "1767323045"
check "iso_to_epoch отвергает мусор" "$(iso_to_epoch 'не дата' >/dev/null 2>&1 && echo принял || echo отверг)" "отверг"

# Гарда версии bash проверяется НА ДЕЛЕ, а не наличием слова BASH_VERSINFO в
# файле: проверка «слово на месте» проходит и на обезвреженной гарде, и именно
# так она первую же мутацию и пропустила. Нужен настоящий старый bash — в macOS
# это штатный /bin/bash 3.2. Там, где его нет (Linux), проверять нечем и блок
# пропускается: лучше честный пропуск, чем тест, который ничего не значит.
old_bash=""
for b in /bin/bash /usr/bin/bash; do
  [ -x "$b" ] || continue
  v=$("$b" -c 'echo ${BASH_VERSINFO[0]}${BASH_VERSINFO[1]}' 2>/dev/null)
  [ -n "$v" ] && [ "$v" -lt 42 ] 2>/dev/null && { old_bash="$b"; break; }
done
if [ -n "$old_bash" ]; then
  check "библиотека отказывается работать на bash < 4.2" \
    "$("$old_bash" -c ". '$REPO_DIR/platform/lib/lib-env.sh'; echo загрузилась" 2>/dev/null)" ""
  check "и называет причину" \
    "$("$old_bash" -c ". '$REPO_DIR/platform/lib/lib-env.sh'" 2>&1 | grep -c 'bash >= 4.2')" "1"
else
  printf '  [--]   bash < 4.2 на этой машине нет — гарду версии проверить нечем\n'
fi

# Сумма — известного содержимого, а не «что-нибудь непустое»: пустая строка
# ровно так и появилась бы при отсутствии обеих команд, а сравнение с непустым
# ожиданием её ловит.
printf 'stackyard' > "$WORK/сумма.txt"
check "sha256_file считает сумму" "$(sha256_file "$WORK/сумма.txt")" \
  "660b926bc79186f63660911f660e1a187daf9fafd1700148d43fb7e02f909bb0"

# Сторож обязан отдавать 124 (как GNU timeout), сохранять уже напечатанное и
# пропускать чужой код возврата. Проверяем ФОЛБЭК — путь, который включается
# там, где timeout'а нет: штатный путь и без теста работает у всех.
guard_out=$(PATH=/usr/bin:/bin run_with_timeout 1 bash -c 'echo раньше; sleep 5; echo позже' 2>/dev/null); guard_rc=$?
check "сторож обрывает зависшее" "$guard_rc" "124"
check "сторож сохраняет напечатанное до обрыва" "$guard_out" "раньше"
PATH=/usr/bin:/bin run_with_timeout 5 bash -c 'exit 7' >/dev/null 2>&1; check "сторож пропускает чужой код возврата" "$?" "7"

echo "== распознавание дампа"

# Прошлая версия объявляла SQLite'ом ЛЮБОЙ gzip. А gzip'ом сжаты и дамп MySQL
# (.sql.gz), и tar источников files:/volume:. В аварийный день дамп базы шёл не
# той веткой восстановления, и в базу не попадало ничего — молча, потому что
# `gunzip -c > цель` отрабатывал успешно.
#
# Проверяем на НАСТОЯЩИХ файлах: распознавание по магии нельзя проверить
# фикстурой из строк.
bkd="$WORK/bk"; mkdir -p "$bkd/dir"
printf 'SQLite format 3\000' > "$bkd/plain.db"
gzip -c "$bkd/plain.db" > "$bkd/base.db.gz"
printf -- '-- dump\nCREATE TABLE t;\n' | gzip -c > "$bkd/mysql.sql.gz"
echo x > "$bkd/dir/f"; tar -czf "$bkd/files.tar.gz" -C "$bkd" dir
printf 'PGDMP\000\000\000\000\000\000\000\000\000\000\000' > "$bkd/pg.dump"

check "SQLite без сжатия"            "$(backup_file_kind "$bkd/plain.db")"     "sqlite_plain"
check "SQLite под gzip"              "$(backup_file_kind "$bkd/base.db.gz")"   "sqlite_gz"
check "дамп SQL под gzip — НЕ SQLite" "$(backup_file_kind "$bkd/mysql.sql.gz")" "unknown"
check "tar под gzip — НЕ SQLite"      "$(backup_file_kind "$bkd/files.tar.gz")" "tar_gz"
check "формат поставщика платформе неизвестен" "$(backup_file_kind "$bkd/pg.dump")" "unknown"

# Ключ seed'а: генератор пишет имя в нижнем регистре без префикса, и второе
# написание в инициализаторе означало бы, что seed молча не накатывается —
# база заведена, схема пуста, приложение падает уже в рантайме.
gen_key=$(printf '%s' "$DB_KEYS_OPTIONAL" | tr 'A-Z ' 'a-z\n' | grep -x dump)
check "генератор пишет ключ seed'а как 'dump'" "$gen_key" "dump"
for init in "$REPO_DIR"/profiles/stacks/*/db-init/initializer.sh; do
  [ -f "$init" ] || continue
  check "$(basename "$(dirname "$(dirname "$init")")"): инициализатор читает тот же ключ" \
    "$(grep -c "yq e '\.dump //" "$init")" "1"
done

echo "== пути в S3"

# Формула пути обязана быть ОДНА на всех потребителей. Разъезд означает, что
# backup.sh кладёт объект по одному пути, а check-backups.sh ищет по другому —
# и вечно докладывает «нет ни одного бэкапа» при исправных бэкапах. Обе стороны
# при этом выглядят работающими, поэтому проверка тут не про значение, а про то,
# что формула ровно одна.
dup=$(grep -hoE 'env_(get|require) Backup_(S3|DB)_Prefix' "$REPO_DIR"/platform/bin/*.sh | sort -u)
check "формулы префиксов не продублированы в bin/" "$dup" ""

# Префикс машины обязателен: бакет бывает общим на несколько машин, и умолчание
# означало бы дампы, уезжающие в чужой каталог поверх чужих. Раньше умолчанием
# было имя конкретной машины.
printf 'Backup_S3_Bucket=b\n' > "$WORK/.env-backup"
ENV_VARS=(); env_load_files "$WORK/.env-backup" >/dev/null 2>&1
check "без Backup_S3_Prefix формула отказывает" \
  "$(backup_s3_prefix 2>/dev/null; echo "код:$?")" "код:1"

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
# Фикстура настраивается ЗДЕСЬ, а не заранее руками.
#
# Её .env, .env-stacks и stacks/*/.env в git не лежат (это .env-файлы, правило
# одно на всех). Значит на свежем клоне их нет, и блок уходил в «пропускаю» —
# а пропуск неотличим от «проверено». Selftest был зелёным только на машине
# автора, где эти файлы остались с прошлых запусков.
#
# Поэтому копируем фикстуру во временный каталог и заводим ей окружение из
# образцов. Заодно это проверяет сами образцы: фикстура, у которой .env.example
# неполон, теперь не настроится.
fixture_machine() {
  local src="$1" dst="$2" f
  mkdir -p "$dst"
  cp -R "$src"/. "$dst"/ 2>/dev/null
  rm -rf "$dst/platform" "$dst/profile" "$dst/.stackyard" "$dst/state"
  ln -sfn "$REPO_DIR/platform" "$dst/platform"
  ln -sfn "$REPO_DIR/profiles" "$dst/profile"
  [ -f "$dst/.env-stacks" ] || cp "$dst/.env-stacks.example" "$dst/.env-stacks" 2>/dev/null
  if [ ! -f "$dst/.env" ] && [ -f "$dst/.env.example" ]; then
    sed "s|^Platform_Deploy_Dir=.*|Platform_Deploy_Dir=$dst|" "$dst/.env.example" > "$dst/.env"
  fi
  # Секреты стеков — из образцов, с подстановкой вместо CHANGE_ME. Значение
  # своё у каждой фикстуры: одинаковый секрет у двух машин — то, что ловит
  # bin/audit-isolation.sh, и заводить его здесь значило бы учить плохому.
  for f in "$dst"/stacks/*/; do
    [ -d "$f" ] || continue
    [ -f "$f/.env" ] && continue
    local ex; ex="$(cd "$REPO_DIR" && ROOT_DIR="$dst" bash -c ". platform/lib/lib-stacks.sh; stack_dir $(basename "${f%/}")")/.env.example"
    [ -f "$ex" ] || ex="$f/.env.example"
    [ -f "$ex" ] && sed "s/CHANGE_ME/$(basename "$dst")-fixture-pw/" "$ex" > "$f/.env"
  done
  # Профильным стекам .env тоже нужен, а их каталога в машине может не быть.
  while IFS= read -r st; do
    [ -n "$st" ] || continue
    local sd; sd="$dst/stacks/$st"
    [ -f "$sd/.env" ] && continue
    local pex="$REPO_DIR/profiles/stacks/$st/.env.example"
    [ -f "$pex" ] || continue
    mkdir -p "$sd"
    sed "s/CHANGE_ME/$(basename "$dst")-fixture-pw/" "$pex" > "$sd/.env"
  done < <(ROOT_DIR="$dst" bash -c ". $REPO_DIR/platform/lib/lib-stacks.sh; stacks_enabled 2>/dev/null")
}

fixtures_seen=0
for src in "$FIXTURES"/*/; do
  [ -d "$src" ] || continue
  name=$(basename "${src%/}")
  m="$WORK/fx-$name"
  fixture_machine "$src" "$m"
  fixtures_seen=$((fixtures_seen + 1))

  # Фикстура обязана быть НЕПУСТОЙ. Без этого все проверки ниже сравнивают
  # пустое с пустым и проходят: ровно так блок и выглядел «зелёным», когда на
  # деле пропускался. Пустое равно пустому — это не проверка.
  enabled_n=$( ROOT_DIR="$m" bash -c ". \"$LIB_DIR/lib-stacks.sh\"; stacks_enabled 2>/dev/null" | grep -c . || true)
  check "$name: фикстура настроена и непуста" \
    "$([ "${enabled_n:-0}" -ge 1 ] && echo да || echo "нет (стеков: ${enabled_n:-0})")" "да"

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

  # Ни одного недостающего файла: если образец неполон, фикстура не настроится,
  # и раньше это было незаметно.
  missing_all=""
  while IFS= read -r st; do
    [ -n "$st" ] || continue
    mf=$( ROOT_DIR="$m" bash -c ". \"$LIB_DIR/lib-stacks.sh\"; stack_missing_files $st" 2>/dev/null )
    [ -n "$mf" ] && missing_all="$missing_all $st:$mf"
  done < <(ROOT_DIR="$m" bash -c ". \"$LIB_DIR/lib-stacks.sh\"; stacks_enabled 2>/dev/null")
  check "$name: у включённых стеков всё на месте" "$missing_all" ""
done

# Пропуск фикстуры неотличим от её проверки, поэтому их число проверяется явно.
# Две с разными СУБД — тот минимум, ради которого фикстуры и существуют.
check "фикстуры действительно прогнаны" "$([ "$fixtures_seen" -ge 2 ] && echo да || echo "нет ($fixtures_seen)")" "да"

echo "== .gitignore"

# Правило `.env*` без исключения молча съедает каждый новый образец: уже
# добавленные файлы продолжают отслеживаться, а новые не попадают в git, и
# обнаруживается это на свежей машине. Поэтому правила проверяются явно.
# Вне git-репозитория check-ignore ответить не может, и его молчание выглядело
# как «файл отслеживается» — шесть ложных провалов на распакованном архиве.
# Отсутствие ответа и ответ «нет» — разные вещи, и путать их нельзя нигде.
if ! ( cd "$REPO_DIR" && git rev-parse --git-dir ) >/dev/null 2>&1; then
  echo "  · это не git-репозиторий — правила .gitignore проверить нечем, блок пропущен"
else

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

fi

echo
if [ "$failures" -eq 0 ]; then
  echo "selftest: всё сошлось"
  exit 0
fi
echo "selftest: провалов: $failures"
exit 1
