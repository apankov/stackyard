#!/usr/bin/env bash
#
# Завести пользователя basic auth для vhost'а.
#
# Через контейнер nginx, а не пакетом apache2-utils на хосте: htpasswd нужен
# раз в полгода, а пакет остался бы на машине навсегда. На этой платформе это
# к тому же единственный путь — host-setup.sh httpd-tools не ставит.
#
# Смысл существования не в удобстве: команду можно набрать и руками. Смысл в
# том, что руками её набирают по первому попавшемуся туториалу, то есть с
# дефолтным APR1-MD5, а файл лежит на машине, смотрящей в интернет. Здесь
# bcrypt зашит, и забыть его нельзя.
#
#   ./platform/bin/htpasswd.sh <файл> <логин>    добавить или сменить пароль
#   ./platform/bin/htpasswd.sh <файл> --list     кто заведён
#
# <файл> — имя внутри state/htpasswd/, оно же в auth_basic_user_file vhost'а
# как /etc/nginx/htpasswd/<файл>. Имя аргументом, а не константой: на машине
# больше одного vhost'а с авторизацией, и общий файл означал бы, что доступ к
# одному сайту открывает и остальные.
#
# Сами файлы в git не лежат (.gitignore).

set -euo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
if [ -z "${ROOT_DIR:-}" ]; then
  ROOT_DIR="$( cd "$DIR0/../.." && pwd )"
  # On a machine, platform/ is a symlink into .stackyard/, and the `cd -P`
  # above has already resolved it: two levels up lands in .stackyard rather
  # than in the machine. state/ would then be created INSIDE the downloaded
  # layer and vanish on the next ./bootstrap, and until then the password
  # files, certificates and databases.yaml would sit where no container looks
  # for them. The wrappers in the machine root set ROOT_DIR themselves, but
  # every script documents being called as ./platform/bin/<name>.sh — that is
  # the path this fixes.
  [ "${ROOT_DIR##*/}" = .stackyard ] && ROOT_DIR="${ROOT_DIR%/*}"
fi
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"

# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"
# shellcheck source=platform/lib/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"
env_load_files "$ROOT_DIR/.env"
# state/, а не platform/: платформа — общий слой, она скачивается bootstrap'ом
# на каждую машину и перезаписывается целиком. Файл basic-auth, положенный туда,
# исчез бы при следующем обновлении платформы, а до того лежал бы секретом в
# слое, который раздаётся всем.
HT_DIR="$ROOT_DIR/state/htpasswd"

NAME="${1:-}"
case "$NAME" in
  ''|--*) echo "usage: $0 <файл> <логин> | $0 <файл> --list" >&2; exit 2 ;;
esac
# Имя файла становится путём внутри контейнера — проверяем, а не экранируем:
# слэш или точки здесь означают запись мимо каталога.
case "$NAME" in
  *[!A-Za-z0-9._-]*|*..*) echo "Ошибка: в имени файла допустимы латиница, цифры, . _ -" >&2; exit 2 ;;
esac
FILE="$HT_DIR/$NAME"

if [ "${2:-}" = "--list" ]; then
  [ -s "$FILE" ] || { echo "пусто: $FILE"; exit 0; }
  cut -d: -f1 "$FILE"
  exit 0
fi

USER_NAME="${2:-}"
[ -n "$USER_NAME" ] || { echo "usage: $0 <файл> <логин> | $0 <файл> --list" >&2; exit 2; }

read -r -s -p "пароль для $USER_NAME в $NAME: " PASS; echo
[ -n "$PASS" ] || { echo "пустой пароль не годится" >&2; exit 2; }

mkdir -p "$HT_DIR"

# bcrypt (-B), а не дефолтный APR1-MD5: файл лежит на машине, смотрящей в
# интернет, и слабый хеш здесь — единственное, что отделяет подобранный пароль
# от того, что за авторизацией.
#
# Пароль идёт через СТДИН (-i), а не аргументом. Аргумент был бы виден в `ps` на
# время работы команды и попал бы в историю оболочки внутри `sh -c`. Ради того
# же логин передан переменной окружения, а не подстановкой в строку команды:
# подстановка логина с кавычкой сломала бы разбор.
#
# Существующий файл ДОПОЛНЯЕТСЯ: `-c` создал бы его заново и молча выкинул
# остальных пользователей.
# -i И -b вместе не бывает: -b означает «пароль ТРЕТЬИМ аргументом», и htpasswd,
# не увидев третьего, печатает usage и выходит. Пароль здесь идёт стдином,
# значит -i, и только он.
FLAGS="-iB"
[ -s "$FILE" ] || FLAGS="-ciB"

# Права и владельца ставит САМ контейнер, пока он ещё root. На хосте это
# сделать нельзя: файл создан контейнером от root, и `chmod` от обычного
# пользователя падает с EPERM — ровно так это и вылезло на сервере.
#
# Владелец — вызвавший, группа — nginx из ТОГО ЖЕ образа, режим 640. Каждая
# часть обязательна: владельцем файл читает человек (--list), группой — рабочий
# процесс nginx (он работает не от root, а от uid 101), а 640 оставляет файл
# закрытым для всех остальных. Раньше выходило root:root 640 — и basic auth
# отвечал бы 403, потому что читать файл было некому.
#
# gid берём из образа, а не константой: он часть чужого образа, а не наша.
# Команда собрана в переменную одной строкой не для красоты: пометка
# # pkg-mgr-ok обязана стоять на той же строке, что apk (гард построчный), а
# внутри многострочного `sh -c "..."` каждая строка кончается обратным слэшем,
# и комментарий туда не поставить.
IN_CONTAINER="apk add --no-cache apache2-utils >/dev/null 2>&1 && htpasswd $FLAGS \"/ht/\$HTFILE\" \"\$HTUSER\" && chown \"\$HTOWNER\":\"\$(id -g nginx)\" \"/ht/\$HTFILE\" && chmod 640 \"/ht/\$HTFILE\""  # pkg-mgr-ok: apk внутри образа nginx:alpine, а не на хосте

printf '%s' "$PASS" | docker run --rm -i \
  -e HTUSER="$USER_NAME" -e HTFILE="$NAME" -e HTOWNER="$(id -u)" \
  -v "$HT_DIR":/ht \
  "$(nginx_image)" \
  sh -c "$IN_CONTAINER"

echo "готово: $FILE"
echo "во vhost'е: auth_basic_user_file /etc/nginx/htpasswd/$NAME;"
echo "перечитать конфиг: docker exec nginx nginx -s reload"
