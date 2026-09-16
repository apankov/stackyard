#!/usr/bin/env bash

# Подготовка машины под девбокс: то, что делается один раз и не относится ни к
# одному стеку в отдельности — пакеты, заглушечные сертификаты, таймеры
# systemd. Хостовые нужды самих стеков делают их же scripts/host-setup.sh.
#
# Смысл существования: эти шаги делались руками и по памяти (bootstrap.sh плюс
# устная традиция), а забытый шаг проявляется не сразу. Забыли таймеры —
# сертификаты не продлеваются, и видно это только когда они кончились.
#
# Скрипт идемпотентен: ставит только недостающее, повторный запуск безопасен.
#
#   sudo ./host-setup            # проверить и доустановить
#   ./host-setup --check         # только проверить, без root и без
#                                           # изменений; код 1 = чего-то нет
#
# Чего он НЕ делает (и не должен): не заполняет секреты, не трогает DNS, не
# поднимает стеки. Это интерактивные шаги, они в README.

set -euo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Каталог МАШИНЫ, а не платформы. Обычно его задаёт обёртка ./stack в корне
# машины; запасной вариант — на два уровня вверх от platform/bin, чтобы скрипт
# работал и при прямом вызове.
ROOT_DIR="${ROOT_DIR:-$( cd "$DIR0/../.." && pwd )}"
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"
ENV_FILE="$ROOT_DIR/.env"

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
elif [ $# -gt 0 ]; then
  echo "Неизвестный аргумент: $1" >&2
  echo "Использование: sudo $0 [--check]" >&2
  exit 2
fi

PROBLEMS=0
WARNINGS=0

# shellcheck source=platform/lib/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"
# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"

# Только платформенные значения. Читаем через lib-env.sh, а не grep'ом: он один
# разворачивает ${...} и снимает кавычки так же, как это делает docker compose,
# — иначе проверка и контейнер видели бы разные значения.
#
# .env стеков здесь НЕ читаются: платформа не знает, какие ключи в них лежат.
# Свои значения проверяет сам стек, в scripts/host-setup.sh.
ENV_VARS=(); env_load_files "$ENV_FILE"

ok()   { echo "  [ok]   $1"; }
warn() { echo "  [!]    $1"; WARNINGS=$((WARNINGS + 1)); }
bad()  { echo "  [FAIL] $1"; PROBLEMS=$((PROBLEMS + 1)); }
step() { echo; echo "== $1"; }

# Пакеты, которые ставит сам скрипт. Каждый — предусловие конкретного шага, а
# не «на всякий случай»: openssl даёт заглушки сертификатов и dhparam, bzip2
# нужен сжатию дампов, gnupg2 — шифрованию бэкапа, logrotate — ротации логов
# nginx (пакета nginx на хосте нет, значит и /etc/logrotate.d/nginx нет).
#
# Список платформенный, а не постековый, намеренно: выключение стека не должно
# снимать пакет, который нужен кому-то ещё.
# Имена ОБЩИЕ; в имена дистрибутива их переводит pkg_name ниже. Общий список
# здесь потому, что предусловие — это возможность (шифровать, сжимать), а не
# строка из каталога пакетов конкретного дистрибутива.
PACKAGES=(logrotate openssl bzip2 gnupg sqlite)

# Менеджер пакетов. Определяем, а не предполагаем: платформа раздаётся, и
# зашитый dnf означает, что на Debian/Ubuntu первая же установка упирается в
# «dnf: command not found» — с подсказкой, которую невозможно выполнить.
PKG_MGR=""
for m in apt-get dnf yum apk zypper; do  # pkg-mgr-ok
  command -v "$m" >/dev/null 2>&1 && { PKG_MGR="$m"; break; }
done

# Имя пакета в терминах дистрибутива. Совпадает не всегда: gnupg против gnupg2,
# sqlite3 против sqlite. Ошибка здесь выглядит как «пакета не существует» — то
# есть как проблема машины, а не как наша.
pkg_name() {
  case "$PKG_MGR:$1" in
    apt-get:gnupg|apk:gnupg)   echo gnupg ;;
    dnf:gnupg|yum:gnupg|zypper:gnupg) echo gnupg2 ;;
    apt-get:sqlite)            echo sqlite3 ;;
    apk:sqlite)                echo sqlite ;;
    *:sqlite)                  echo sqlite ;;
    *)                         echo "$1" ;;
  esac
}

pkg_installed() {
  case "$PKG_MGR" in
    apt-get) dpkg -s "$1" >/dev/null 2>&1 ;;  # pkg-mgr-ok
    dnf|yum|zypper) rpm -q "$1" >/dev/null 2>&1 ;;  # pkg-mgr-ok
    apk)     apk info -e "$1" >/dev/null 2>&1 ;;  # pkg-mgr-ok
    *)       return 1 ;;
  esac
}

pkg_install_cmd() {
  case "$PKG_MGR" in
    apt-get) echo "sudo apt-get install -y" ;;  # pkg-mgr-ok
    dnf)     echo "sudo dnf install -y" ;;  # pkg-mgr-ok
    yum)     echo "sudo yum install -y" ;;  # pkg-mgr-ok
    apk)     echo "sudo apk add" ;;  # pkg-mgr-ok
    zypper)  echo "sudo zypper install -y" ;;  # pkg-mgr-ok
    *)       echo "(менеджер пакетов не определён)" ;;
  esac
}

# ---------------------------------------------------------------- 1. базовое

step "Окружение"

if [ "$CHECK_ONLY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "Ошибка: нужны права root. Запустите: sudo $0" >&2
  echo "  Либо посмотрите, чего не хватает, без изменений: $0 --check" >&2
  exit 1
fi

command -v systemctl >/dev/null 2>&1 \
  && ok "systemd на месте" \
  || bad "нет systemctl — таймеры ставить нечем, машине нужен другой планировщик"

if command -v docker >/dev/null 2>&1; then
  ok "docker: $(docker --version 2>/dev/null | head -n 1)"
  if docker compose version >/dev/null 2>&1; then
    ok "docker compose (плагин v2)"
  else
    bad "нет 'docker compose' — docker-compose.sh не заработает (нужен плагин v2, не docker-compose v1)"
  fi
  docker info >/dev/null 2>&1 \
    && ok "демон docker отвечает" \
    || bad "демон docker не отвечает: sudo systemctl enable --now docker"
else
  # Установку docker намеренно не автоматизируем: она тянет за собой членство
  # в группе docker, а оно применяется только после перелогина — то есть
  # скрипт всё равно не смог бы завершить дело за один проход.
  bad "нет docker. Поставить его пакетом вашего дистрибутива, затем: sudo systemctl enable --now docker && sudo usermod -aG docker \$USER (и перелогиниться)"
fi

# ------------------------------------------------------ 2. внешний том

DATA_MOUNT="$(env_get Platform_Data_Mount)"
if [ -n "$DATA_MOUNT" ]; then
  step "Внешний том $DATA_MOUNT"

  # Машина, у которой данные лежат на ОТДЕЛЬНОМ томе, объявляет его в
  # Platform_Data_Mount. Если том не смонтирован, `docker run -v` заводит под
  # точкой монтирования пустые каталоги, а СУБД инициализирует в них чистый
  # датадир. Снаружи это неотличимо от потери данных: сайт открывается, базы
  # пустые, и всё записано на не тот диск. Поэтому [FAIL], а не предупреждение.
  #
  # Пустое значение — законное состояние, а не забывчивость: на машине, где
  # /mnt/data просто каталог корневого раздела, эта проверка была бы вечной
  # ложной тревогой, а ложная тревога быстро учит не читать отчёт.
  if mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
    ok "$DATA_MOUNT смонтирован"
  else
    bad "$DATA_MOUNT НЕ точка монтирования — внешний том не подключён; базы поднимать нельзя"
    echo "         Проверить: lsblk; findmnt $DATA_MOUNT"
  fi
else
  step "Внешний том"
  ok "Platform_Data_Mount не задан — отдельного тома на этой машине нет"
fi

# ------------------------------------------------------------------ 3. .env

step "Вендоренные слои"

# Раньше остальных проверок: если платформа на машине не та, что заявлена, или
# её правили на месте, всё, что проверяется ниже, проверяется не тем кодом.
"$DIR0/check-vendor.sh" | sed 's/^/  /' || PROBLEMS=$((PROBLEMS + 1))

step "Файлы окружения"

if [ ! -f "$ENV_FILE" ]; then
  bad "нет $ENV_FILE — cp .env.example .env && chmod 600 .env, затем заполнить"
else
  ok ".env на месте"

  DEPLOY=$(env_get Platform_Deploy_Dir)
  # Частый способ выстрелить себе в ногу: .env скопировали с другой машины, и
  # он указывает на чужой путь. Всё остальное после этого «работает», но
  # монтирует не тот каталог.
  if [ "$DEPLOY" != "$ROOT_DIR" ]; then
    bad "Platform_Deploy_Dir='$DEPLOY', а репозиторий лежит в '$ROOT_DIR'"
  else
    ok "Platform_Deploy_Dir совпадает с каталогом репозитория"
  fi

  NET=$(env_get Platform_Network)

  if [ -z "$NET" ]; then
    bad "Platform_Network не задана в .env"
  elif docker network inspect "$NET" >/dev/null 2>&1; then
    ok "docker-сеть '$NET' существует"
  else
    warn "docker-сети '$NET' пока нет — её создаст docker-compose.sh при первом запуске"
  fi
fi

# Какие стеки включены и чего им не хватает — спрашиваем у lib-stacks.sh, а не
# перечисляем здесь: состав определяет Enabled_Stacks в .env-stacks, и второй
# список означал бы ровно тот разъезд, от которого этот скрипт защищает.
if [ -f "$ROOT_DIR/.env-stacks" ]; then
  ok ".env-stacks (включено: $(stacks_enabled 2>/dev/null | tr '\n' ' '))"
else
  warn "нет .env-stacks — включёнными считаются все стеки с полным набором файлов (cp .env-stacks.example .env-stacks)"
fi

for stack in $(stacks_enabled 2>/dev/null); do
  missing=$(stack_missing_files "$stack" | tr '\n' ' ')
  if [ -z "$(echo $missing)" ]; then
    ok "стек $stack: файлы на месте"
  else
    for f in $missing; do
      if [ -f "$ROOT_DIR/$f.example" ]; then
        bad "стек $stack: нет $f — cp $f.example $f && chmod 600 $f, затем заполнить секреты"
      else
        bad "стек $stack: нет $f"
      fi
    done
  fi
done

# ---------------------------------------------------------------- 4. пакеты

step "Незаполненные секреты"

# Образцы .env несут CHANGE_ME там, где значение обязано быть задано: без него
# `--examples` не смог бы проверить синтаксис compose на машине без секретов.
# Цена этого удобства — плейсхолдер, который легко скопировать и не заметить,
# поэтому он проверяется здесь. Ищем по ЗНАЧЕНИЮ, а не по списку ключей:
# платформа не знает, какие ключи заведёт очередной стек.
left=0
for f in "$ROOT_DIR"/.env "$ROOT_DIR"/.env-backup "$ROOT_DIR"/.env-notify "$ROOT_DIR"/stacks/*/.env; do
  [ -f "$f" ] || continue
  while IFS= read -r line; do
    case "$line" in \#*|'') continue ;; esac
    case "${line#*=}" in
      CHANGE_ME|'"CHANGE_ME"'|"'CHANGE_ME'")
        bad "${f#"$ROOT_DIR"/}: ${line%%=*} не заполнен (осталось CHANGE_ME)"; left=$((left + 1)) ;;
    esac
  done < "$f"
done
[ "$left" -eq 0 ] && ok "незаполненных значений нет"

step "Пакеты"

if [ -z "$PKG_MGR" ]; then
  bad "менеджер пакетов не опознан (искали apt-get, dnf, yum, apk, zypper)"
  echo "         Поставьте вручную: ${PACKAGES[*]}"
else
  MISSING_PKGS=()
  for pkg in "${PACKAGES[@]}"; do
    real="$(pkg_name "$pkg")"
    if pkg_installed "$real"; then ok "$real"; else MISSING_PKGS+=("$real"); fi
  done

  if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    if [ "$CHECK_ONLY" -eq 1 ]; then
      bad "не установлены: ${MISSING_PKGS[*]} ($(pkg_install_cmd) ${MISSING_PKGS[*]})"
    else
      echo "  ... установка ($PKG_MGR): ${MISSING_PKGS[*]}"
      case "$PKG_MGR" in
        apt-get) apt-get update -qq && apt-get install -y "${MISSING_PKGS[@]}" ;;  # pkg-mgr-ok
        dnf|yum) "$PKG_MGR" install -y "${MISSING_PKGS[@]}" ;;  # pkg-mgr-ok
        apk)     apk add "${MISSING_PKGS[@]}" ;;  # pkg-mgr-ok
        zypper)  zypper install -y "${MISSING_PKGS[@]}" ;;  # pkg-mgr-ok
      esac
      for pkg in "${MISSING_PKGS[@]}"; do ok "$pkg (установлен)"; done
    fi
  fi
fi

# --------------------------------------------------- 5. хостовая часть стеков

step "Хостовая часть стеков"

# Не всё, что нужно стеку, живёт в контейнере. Стеку php-fpm нужен шим
# /usr/local/bin/php, стеку mysql — _db/db.conf. Раньше и то, и другое стояло
# прямо здесь, и платформа знала про PHP и про MySQL.
#
# Теперь это делает сам стек: наличие scripts/host-setup.sh — и есть
# объявление, отдельного ключа для него не нужно, как и для health.sh.
# Контракт: идемпотентен, понимает --check (ничего не менять, ненулевой код
# при нехватке), получает в окружении ROOT_DIR и STACK_DIR.
for stack in $(stacks_enabled 2>/dev/null); do
  hook="$(stack_dir "$stack")/scripts/host-setup.sh"
  [ -x "$hook" ] || continue
  if [ "$CHECK_ONLY" -eq 1 ]; then
    ROOT_DIR="$ROOT_DIR" STACK_DIR="$(stack_dir "$stack")" "$hook" --check 2>&1 | sed "s/^/  [$stack] /" \
      || PROBLEMS=$((PROBLEMS + 1))
  else
    ROOT_DIR="$ROOT_DIR" STACK_DIR="$(stack_dir "$stack")" "$hook" 2>&1 | sed "s/^/  [$stack] /"
  fi
done

# ------------------------------------------------------------------ 7. swap

TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
SWAP_MB=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
if [ "${TOTAL_MB:-0}" -gt 0 ]; then
  step "Память"
  if [ "$SWAP_MB" -eq 0 ] && [ "$TOTAL_MB" -lt 4096 ]; then
    warn "RAM ${TOTAL_MB}M, swap нет — сборка образов может упасть по памяти"
  else
    ok "RAM ${TOTAL_MB}M, swap ${SWAP_MB}M"
  fi
fi

# ------------------------------------------------- 8. сертификаты и таймеры

step "Заглушки сертификатов и таймеры"

if [ "$CHECK_ONLY" -eq 1 ]; then
  [ -f "$ROOT_DIR/state/certs/nginx-selfsigned.crt" ] \
    && ok "заглушечный сертификат есть" \
    || bad "нет заглушек сертификатов — ./platform/bin/certs.sh (без них nginx не стартует с новым vhost)"

  # Платформенные таймеры — всегда; таймеры стеков — по включённым. Поимённый
  # список означал бы, что на машине без такого стека проверка требует таймер,
  # которого там быть и не должно.
  EXPECTED_TIMERS=(getssl-renew.timer getssl-check.timer)
  while IFS= read -r stack; do
    [ -n "$stack" ] || continue
    while IFS= read -r unit; do
      case "$unit" in *.timer) EXPECTED_TIMERS+=("$(basename "$unit")") ;; esac
    done < <(stack_units "$stack")
  done < <(stacks_enabled 2>/dev/null)
  [ -f "$ROOT_DIR/.env-backup" ] && EXPECTED_TIMERS+=(devbox-backup.timer devbox-backup-check.timer)
  [ -f "$ROOT_DIR/.env-notify" ] && EXPECTED_TIMERS+=(devbox-watch.timer devbox-heartbeat.timer)

  for t in "${EXPECTED_TIMERS[@]}"; do
    systemctl is-enabled "$t" >/dev/null 2>&1 \
      && ok "$t включён" \
      || bad "$t не установлен — sudo ./platform/bin/systemd.sh"
  done

  # Старый планировщик. Оставленная строка в кроне означает, что getssl
  # работает дважды — из cron и из таймера, — а два параллельных продления
  # спорят за один ACME-аккаунт и за один каталог.
  if sudo -n true 2>/dev/null || [ "$(id -u)" -eq 0 ]; then
    # Ищем по путям ЭТОЙ машины, а не по зашитому имени: имя конкретного
    # девбокса в платформе означало бы, что на любой другой машине проверка
    # молча проходит, ничего не найдя.
    if grep -qsF "$ROOT_DIR" /etc/crontab /etc/cron.d/* 2>/dev/null \
       || grep -qsE 'getssl|backup\.sh' /etc/crontab /etc/cron.d/* 2>/dev/null; then
      bad "в cron остались задачи этой машины — они дублируют таймеры systemd; уберите их"
      grep -nsE "$ROOT_DIR|getssl|backup\.sh" /etc/crontab /etc/cron.d/* 2>/dev/null | sed 's/^/         /'
    else
      ok "в cron задач этой машины нет"
    fi
  fi
else
  # certs.sh — от имени владельца репозитория, а НЕ от root: getssl в таймере
  # работает под этим же пользователем и позже перезапишет заглушки настоящими
  # сертификатами. Root-овые файлы он молча заменить не сможет.
  SERVICE_USER=$(stat -c '%U' "$ROOT_DIR" 2>/dev/null || stat -f '%Su' "$ROOT_DIR")
  echo "  ... заглушки сертификатов (от имени $SERVICE_USER)"
  sudo -u "$SERVICE_USER" "$DIR0/certs.sh" | sed 's/^/      /'

  echo "  ... таймеры systemd"
  "$DIR0/systemd.sh" | sed 's/^/      /'
fi

# ------------------------------------------------------------------ 9. итог

echo
if [ "$PROBLEMS" -gt 0 ]; then
  echo "Не готово: проблем — $PROBLEMS, предупреждений — $WARNINGS."
  [ "$CHECK_ONLY" -eq 1 ] && echo "Починить то, что чинится автоматически: sudo $0"
  exit 1
fi

echo "Хост готов. Предупреждений: $WARNINGS."
echo
echo "Проверить состояние в любой момент:"
echo "  $0 --check"
echo "  ./stack --check"
echo "  systemctl list-timers 'getssl-*' 'devbox-*'"
