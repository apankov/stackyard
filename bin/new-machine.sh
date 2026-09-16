#!/usr/bin/env bash
#
# Завести репозиторий новой машины.
#
# Машина — ОТДЕЛЬНЫЙ репозиторий, приватный. В stackyard её нет и быть не
# может: stackyard публичный, и домены с именами стеков одного клиента не
# должны лежать там, где их прочитает другой.
#
# В машину кладётся: скелет каталогов, обёртки, образцы .env, .gitignore и
# bootstrap с закреплённой версией stackyard. Сама платформа — НЕ кладётся:
# её приносит bootstrap и держит в .stackyard/, вне git.
#
#   ./bin/new-machine.sh ~/dev/machines/client-acme
#   ./bin/new-machine.sh ~/dev/machines/client-acme --repo https://github.com/me/stackyard.git

set -euo pipefail

ROOT="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
DEST=""; REPO="https://github.com/apankov/stackyard.git"

while [ $# -gt 0 ]; do
  case "$1" in
    # ${2-}, а не "$2": под set -u забытое значение даёт «$2: unbound
    # variable» вместо внятного «--repo требует значение».
    --repo) REPO="${2-}"; [ -n "$REPO" ] || { echo "Ошибка: --repo требует значение" >&2; exit 2; }; shift 2 ;;
    -*) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
    *)  DEST="$1"; shift ;;
  esac
done
[ -n "$DEST" ] || { echo "Использование: $0 <путь-к-новой-машине> [--repo <url>]" >&2; exit 2; }
[ -e "$DEST" ] && { echo "Ошибка: $DEST уже существует" >&2; exit 2; }

NAME="$(basename "$DEST")"
VERSION="v$(cat "$ROOT/platform/VERSION")"
COMMIT="$( cd "$ROOT" && git rev-parse HEAD )"

mkdir -p "$DEST"/{stacks,state/htpasswd,state/certs,dumps,gpg,nginx}
touch "$DEST/state/.keepit" "$DEST/dumps/.keepit" "$DEST/gpg/.keepit" "$DEST/nginx/.keepit"

# Образцы бэкапа и оповещений. Файлы отдельные от .env намеренно: они НЕ входят
# в список --env-file docker-compose.sh, и лишний обязательный env-файл был бы
# ещё одним способом уронить все compose-команды разом.
cp "$ROOT/templates/machine/.env-backup.example" "$DEST/.env-backup.example"
cp "$ROOT/templates/machine/.env-notify.example" "$DEST/.env-notify.example"

cp "$ROOT/templates/machine/bootstrap" "$DEST/bootstrap"
chmod +x "$DEST/bootstrap"

cat > "$DEST/stackyard.lock" <<EOF
# На какой версии stackyard работает эта машина.
#
# Закрепление по КОММИТУ, а не по хешу архива: автоматические архивы GitHub
# байт-стабильными не гарантированы, а коммит неизменен по определению.
# Тег нужен только чтобы клонировать дешёво; если его передвинут, bootstrap
# откажется работать, а не подсунет чужой код.
#
# Обновить: ./bin/pin.sh <эта-машина> из stackyard, затем ./bootstrap здесь.
repo=$REPO
version=$VERSION
commit=$COMMIT
EOF

# Обёртки. Три строки каждая, и они единственная причина, по которой из корня
# машины можно набрать ./stack вместо полного пути внутрь платформы.
while IFS=: read -r name target; do
  case "$name" in ''|\#*) continue ;; esac
  sed "s/@TARGET@/$target/g" "$ROOT/templates/machine/wrapper" > "$DEST/$name"
  chmod +x "$DEST/$name"
done < "$ROOT/templates/machine/wrappers"

cat > "$DEST/.gitignore" <<'EOF'
# Платформа. В git машины её нет намеренно: она приезжает по stackyard.lock,
# и копия в репозитории означала бы второй источник правды о том, какой код
# на машине работает.
/.stackyard/
/platform
/profile

# Секреты и состояние машины.
.env
.env-stacks
.env-backup
.env-notify
stacks/*/.env
!.env.example
!.env-stacks.example
!stacks/*/.env.example
!.env-backup.example
!.env-notify.example
state/*
!state/.keepit
dumps/*
!dumps/.keepit
EOF

cat > "$DEST/.env.example" <<EOF
# Платформенное. Загружается всегда, для любой compose-команды.
#   cp .env.example .env && chmod 600 .env

# Куда развёрнут ЭТОТ репозиторий на сервере.
Platform_Deploy_Dir=/mnt/data/$NAME
# Docroot'ы сайтов, вне репозитория.
Platform_Vhosts_Dir=/mnt/data/vhosts
Platform_Vhosts_Mount=/var/www/vhosts
# Имя docker-сети. Своё у каждой машины — audit-isolation это проверяет.
Platform_Network=$NAME-net
# Отдельный том с данными. Пусто, если такого тома нет.
Platform_Data_Mount=/mnt/data
EOF

cat > "$DEST/.env-stacks.example" <<'EOF'
# Какие стеки включены. Единственный источник правды о составе машины.
# Стеки берутся из profile/stacks (общие) и stacks/ (свои).
Enabled_Stacks=""
EOF

cat > "$DEST/README.md" <<EOF
# $NAME

Машина на stackyard. Платформа в git не лежит — её приносит \`./bootstrap\`
по версии из \`stackyard.lock\`.

## Развернуть

\`\`\`sh
git clone <этот репозиторий> /mnt/data/$NAME
cd /mnt/data/$NAME
./bootstrap                     # платформа $VERSION
cp .env.example .env && \$EDITOR .env
cp .env-stacks.example .env-stacks && \$EDITOR .env-stacks
sudo ./host-setup
./stack enable <стеки>
\`\`\`

## Обновить платформу

Из stackyard на ноутбуке: \`./bin/pin.sh <путь-к-этой-машине>\`, коммит здесь,
на сервере \`git pull && ./bootstrap && ./stack --check\`.
EOF

echo "Машина заведена: $DEST"
echo "  stackyard: $VERSION ($COMMIT)"
echo
echo "Дальше:"
echo "  cd $DEST && git init && ./bootstrap"
echo "  заполнить .env и .env-stacks, описать стеки в stacks/"
