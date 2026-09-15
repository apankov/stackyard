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

# shellcheck source=lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"
# shellcheck source=lib-env.sh
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
PACKAGES=(logrotate openssl bzip2 gnupg2)

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
  bad "нет docker. Поставить: sudo dnf install -y docker && sudo systemctl enable --now docker && sudo usermod -aG docker \$USER (затем перелогиниться)"
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

step "Пакеты"

MISSING_PKGS=()
for pkg in "${PACKAGES[@]}"; do
  if rpm -q "$pkg" >/dev/null 2>&1; then ok "$pkg"; else MISSING_PKGS+=("$pkg"); fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
  if [ "$CHECK_ONLY" -eq 1 ]; then
    bad "не установлены: ${MISSING_PKGS[*]} (sudo dnf install -y ${MISSING_PKGS[*]})"
  else
    echo "  ... установка: ${MISSING_PKGS[*]}"
    dnf install -y "${MISSING_PKGS[@]}"
    for pkg in "${MISSING_PKGS[@]}"; do ok "$pkg (установлен)"; done
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
    if grep -qsE 'devbox6|backuper|getssl' /etc/crontab /etc/cron.d/* 2>/dev/null; then
      bad "в cron остались задачи devbox6 — они дублируют таймеры systemd; уберите их"
    else
      ok "в cron задач devbox6 нет"
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
