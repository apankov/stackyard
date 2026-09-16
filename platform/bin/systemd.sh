#!/usr/bin/env bash

# Установка таймеров systemd: продление сертификатов через getssl, проверка
# сроков, суточный бэкап баз в S3 с его собственной проверкой, оповещения в
# Telegram (обработчик OnFailure, наблюдение за хостом, еженедельная сводка) —
# и юниты, которые приносят с собой сами стеки.
#
# Пакета cronie на этой машине нет вовсе; systemd здесь уже есть, ставить
# нечего.
#
# Скрипт идемпотентен: повторный запуск переустанавливает юниты и перечитывает
# конфигурацию, ничего не ломая.

set -euo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Каталог МАШИНЫ, а не платформы. Обычно его задаёт обёртка ./stack в корне
# машины; запасной вариант — на два уровня вверх от platform/bin, чтобы скрипт
# работал и при прямом вызове.
ROOT_DIR="${ROOT_DIR:-$( cd "$DIR0/../.." && pwd )}"
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"
ENV_FILE="$ROOT_DIR/.env"
UNIT_SRC="$ROOT_DIR/platform/systemd"
UNIT_DST="/etc/systemd/system"

BACKUP_ENV_FILE="$ROOT_DIR/.env-backup"
NOTIFY_ENV_FILE="$ROOT_DIR/.env-notify"

# Юниты бэкапа и оповещений добавляются ниже, если на машине настроены
# соответствующие части. Продление сертификатов ставится всегда.
#
# Юниты СТЕКОВ здесь не перечисляются вовсе: их приносит проход по
# stacks/<стек>/systemd/ (блок 4). Иначе стек, которому понадобился таймер, был
# бы обязан править этот скрипт.
UNITS=(getssl-renew.service getssl-renew.timer getssl-check.service getssl-check.timer)
TIMERS=(getssl-renew.timer getssl-check.timer)

# 1. Проверяем наличие .env
if [ ! -f "$ENV_FILE" ]; then
  echo "Ошибка: Файл окружения '$ENV_FILE' не найден!" >&2
  exit 1
fi

# `|| true` обязателен: при set -euo pipefail отсутствие строки в .env даёт
# ненулевой код grep, pipefail протаскивает его через конвейер, а set -e
# убивает скрипт прямо на присваивании — до проверки ниже, которая должна
# была объяснить, что не так.
Platform_Deploy_Dir=$(grep -E '^Platform_Deploy_Dir=' "$ENV_FILE" | head -n 1 | cut -d '=' -f2- | tr -d '"'\' || true)

if [ -z "$Platform_Deploy_Dir" ]; then
  echo "Ошибка: Переменная Platform_Deploy_Dir не задана в файле $ENV_FILE" >&2
  exit 1
fi

# 2. Предполётные проверки. Каждая из них — отказ, который иначе проявился бы
#    только через сутки, в 05:23, и молча.
if ! command -v systemctl >/dev/null 2>&1; then
  echo "Ошибка: systemd не найден. Этой машине нужен другой планировщик." >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Ошибка: нужны права root. Запустите: sudo $0" >&2
  exit 1
fi

# Platform_Deploy_Dir — это путь НА машине; на ней же мы и стоим.
if [ ! -d "$Platform_Deploy_Dir/state/getssl-config" ]; then
  echo "Ошибка: нет $Platform_Deploy_Dir/state/getssl-config" >&2
  echo "  Platform_Deploy_Dir в .env указывает не туда, где лежит репозиторий." >&2
  exit 1
fi

if [ ! -x "$Platform_Deploy_Dir/platform/getssl" ]; then
  echo "Ошибка: $Platform_Deploy_Dir/platform/getssl не найден или не исполняем" >&2
  exit 1
fi

# От чьего имени крутить таймеры: владелец каталога репозитория. Он же владеет
# state/certs, куда getssl пишет результат.
SERVICE_USER=$(stat -c '%U' "$Platform_Deploy_Dir" 2>/dev/null || stat -f '%Su' "$Platform_Deploy_Dir")

if [ -z "$SERVICE_USER" ] || [ "$SERVICE_USER" = "root" ]; then
  echo "Ошибка: владелец $Platform_Deploy_Dir — '$SERVICE_USER'." >&2
  echo "  Ожидался обычный пользователь (ec2-user), от которого работает деплой." >&2
  exit 1
fi

# RELOAD_CMD в каждом getssl.cfg — это "docker exec nginx nginx -s reload".
# Без членства в группе docker продление пройдёт, а nginx останется со старым
# сертификатом в памяти: худший вид отказа — тихий и частичный.
if ! id -nG "$SERVICE_USER" | tr ' ' '\n' | grep -qx docker; then
  echo "Ошибка: пользователь '$SERVICE_USER' не состоит в группе docker." >&2
  echo "  RELOAD_CMD ('docker exec nginx nginx -s reload') не сработает," >&2
  echo "  и nginx продолжит отдавать старый сертификат после продления." >&2
  echo "  Исправление: sudo usermod -aG docker $SERVICE_USER" >&2
  exit 1
fi

# 2c. Бэкап баз. Тоже пропуск, а не отказ: машина без настроенного S3 — это
#     нормальное состояние свежего девбокса, и оно не повод оставить
#     сертификаты без продления. Пропуск громкий, в stderr.
#
#     Проверяем именно предусловия, а не только наличие файла: конфиг с пустым
#     бакетом или без публичного ключа даёт таймер, который каждую ночь молча
#     падает, — а это ровно тот отказ, от которого мы защищаемся.
INSTALL_BACKUP=1
BACKUP_SKIP=""
BACKUP_BUCKET=""
BACKUP_PUBKEY=""

if [ ! -f "$BACKUP_ENV_FILE" ]; then
  INSTALL_BACKUP=0
  BACKUP_SKIP="нет $BACKUP_ENV_FILE (cp .env-backup.example .env-backup && chmod 600)"
else
  BACKUP_BUCKET=$(grep -E '^Backup_S3_Bucket=' "$BACKUP_ENV_FILE" | head -n 1 | cut -d '=' -f2- | tr -d '"'\' || true)
  BACKUP_PUBKEY=$(grep -E '^Backup_GPG_Pubkey=' "$BACKUP_ENV_FILE" | head -n 1 | cut -d '=' -f2- | tr -d '"'\' || true)
  [ -z "$BACKUP_PUBKEY" ] && BACKUP_PUBKEY="platform/gpg/backup-pubkey.asc"
  case "$BACKUP_PUBKEY" in /*) ;; *) BACKUP_PUBKEY="$ROOT_DIR/$BACKUP_PUBKEY" ;; esac

  if [ -z "$BACKUP_BUCKET" ]; then
    INSTALL_BACKUP=0
    BACKUP_SKIP="Backup_S3_Bucket не задан в $BACKUP_ENV_FILE"
  elif [ ! -f "$BACKUP_PUBKEY" ]; then
    INSTALL_BACKUP=0
    BACKUP_SKIP="нет публичного GPG-ключа $BACKUP_PUBKEY (генерируется НЕ на этой машине, см. README)"
  elif ! command -v aws >/dev/null 2>&1; then
    INSTALL_BACKUP=0
    BACKUP_SKIP="нет команды aws — поставьте awscli пакетом дистрибутива"
  fi
fi

if [ "$INSTALL_BACKUP" -eq 1 ]; then
  UNITS+=(devbox-backup.service devbox-backup.timer devbox-backup-check.service devbox-backup-check.timer)
  TIMERS+=(devbox-backup.timer devbox-backup-check.timer)
else
  echo "ВНИМАНИЕ: бэкап баз пропущен — $BACKUP_SKIP" >&2
fi

# 2d. Оповещения в Telegram. От них зависит подстановка @ONFAILURE@ во ВСЕ
#     остальные юниты, поэтому блок стоит до цикла установки.
#
#     Юнит с OnFailure на необъявленный обработчик работал бы, но при каждом
#     сбое сыпал бы в журнал ошибкой о ненайденном юните — то есть шумел бы
#     ровно там, куда смотрят, разбирая сбой.
INSTALL_NOTIFY=1
NOTIFY_SKIP=""
ONFAILURE_LINE=""

if [ ! -f "$NOTIFY_ENV_FILE" ]; then
  INSTALL_NOTIFY=0
  NOTIFY_SKIP="нет $NOTIFY_ENV_FILE (cp .env-notify.example .env-notify && chmod 600)"
else
  NOTIFY_TOKEN=$(grep -E '^Notify_Telegram_Token=' "$NOTIFY_ENV_FILE" | head -n 1 | cut -d '=' -f2- | tr -d '"'\' || true)
  NOTIFY_CHAT=$(grep -E '^Notify_Telegram_Chat_Id=' "$NOTIFY_ENV_FILE" | head -n 1 | cut -d '=' -f2- | tr -d '"'\' || true)
  if [ -z "$NOTIFY_TOKEN" ] || [ -z "$NOTIFY_CHAT" ]; then
    INSTALL_NOTIFY=0
    NOTIFY_SKIP="в $NOTIFY_ENV_FILE не заполнены Notify_Telegram_Token и/или Notify_Telegram_Chat_Id"
  elif ! command -v curl >/dev/null 2>&1; then
    INSTALL_NOTIFY=0
    NOTIFY_SKIP="нет команды curl"
  fi
fi

if [ "$INSTALL_NOTIFY" -eq 1 ]; then
  # Шаблон devbox-notify@.service именно копируется, а не включается: у
  # шаблонных юнитов нет [Install], их запускает OnFailure по имени экземпляра.
  UNITS+=(devbox-notify@.service devbox-watch.service devbox-watch.timer
          devbox-heartbeat.service devbox-heartbeat.timer)
  TIMERS+=(devbox-watch.timer devbox-heartbeat.timer)
  ONFAILURE_LINE="OnFailure=devbox-notify@%n.service"
else
  echo "ВНИМАНИЕ: оповещения в Telegram пропущены — $NOTIFY_SKIP" >&2
  echo "         сбои будут видны только в \`systemctl --failed\`." >&2
fi

echo "** Установка таймеров в $UNIT_DST"
echo "   репозиторий: $Platform_Deploy_Dir"
echo "   пользователь: $SERVICE_USER"
if [ "$INSTALL_BACKUP" -eq 1 ]; then
  echo "   бэкап баз: s3://$BACKUP_BUCKET"
fi
if [ "$INSTALL_NOTIFY" -eq 1 ]; then
  echo "   оповещения: telegram, чат $NOTIFY_CHAT"
fi

# 3. Подстановка путей. Юниты systemd не умеют переменных и требуют абсолютных
#    путей, поэтому в репозитории они лежат шаблонами с @DEPLOY_DIR@.
for unit in "${UNITS[@]}"; do
  if [ ! -f "$UNIT_SRC/$unit" ]; then
    echo "Ошибка: нет шаблона $UNIT_SRC/$unit" >&2
    exit 1
  fi
  sed -e "s#@DEPLOY_DIR@#${Platform_Deploy_Dir}#g" \
      -e "s#@SERVICE_USER@#${SERVICE_USER}#g" \
      -e "s#@ONFAILURE@#${ONFAILURE_LINE}#g" \
      "$UNIT_SRC/$unit" > "$UNIT_DST/$unit"
  chmod 644 "$UNIT_DST/$unit"
  echo "    -> $unit"
done

# 4. Юниты включённых стеков. Стек, которому нужен таймер, кладёт юнит в
# stacks/<стек>/systemd/ и этот скрипт не трогает.

# shellcheck source=platform/lib/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"
export DEPLOY_DIR="$Platform_Deploy_Dir"
export SERVICE_USER
export ONFAILURE="$ONFAILURE_LINE"

STACK_TIMERS=()
while IFS= read -r stack; do
  [ -n "$stack" ] || continue
  units=$(stack_units "$stack")
  [ -n "$units" ] || continue

  # Предполётная проверка стека. Ненулевой код — юниты НЕ ставятся, и причина
  # называется вслух.
  #
  # Условие внутри самого юнита (ConditionPathExists) для этого не годится:
  # оно молчит. Таймер срабатывает, ничего не делает и снаружи неотличим от
  # исправного — то есть отказ выглядит как норма, а это худший исход. Таймер,
  # падающий каждую ночь, плох; таймер, тихо не делающий ничего, хуже.
  # Через stack_dir, а не сборкой пути: стек может лежать и в машинном stacks/,
  # и в профильном profile/stacks/. Собранный строкой путь слеп ко второму, и
  # preflight профильного стека молча не выполнялся бы — то есть юниты вставали
  # бы стеку, который к работе не готов. Ровно та тишина, от которой этот
  # preflight и защищает.
  preflight="$(stack_dir "$stack")/scripts/preflight.sh"
  if [ -x "$preflight" ]; then
    if ! reason=$("$preflight" 2>&1); then
      echo "ВНИМАНИЕ: юниты стека '$stack' пропущены — ${reason:-preflight.sh вернул ошибку}" >&2
      continue
    fi
  fi

  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    name=$(basename "$unit")
    # /etc/systemd/system плоский: без префикса два стека подерутся за имя, и
    # победит тот, чьи юниты поставили последними.
    case "$name" in
      devbox-"$stack"-*) ;;
      *) echo "ВНИМАНИЕ: $name пропущен — имя юнита стека должно начинаться с devbox-$stack-" >&2
         continue ;;
    esac
    unit_render "$unit" "$stack" > "$UNIT_DST/$name"
    chmod 644 "$UNIT_DST/$name"
    case "$name" in *.timer) STACK_TIMERS+=("$name") ;; esac
    echo "    -> $name (стек $stack)"
  done <<< "$units"
done < <(stacks_enabled)

TIMERS+=("${STACK_TIMERS[@]}")

# 4b. Снятие юнитов выключенных стеков.
#
# Без этого выключенный стек продолжал бы будить машину по своему таймеру.
# `stack.sh disable` сделать этого не может — он работает без root — и потому
# лишь советует запустить этот скрипт.
enabled_now=" $(stacks_enabled 2>/dev/null | tr '\n' ' ') "
while IFS= read -r stack; do
  [ -n "$stack" ] || continue
  case "$enabled_now" in *" $stack "*) continue ;; esac
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    name=$(basename "$unit")
    [ -f "$UNIT_DST/$name" ] || continue
    systemctl disable --now "$name" >/dev/null 2>&1 || true
    rm -f "$UNIT_DST/$name"
    echo "    снят $name (стек $stack выключен)"
  done < <(stack_units "$stack")
done < <(stacks_available)

# 5. Перечитать и включить
systemctl daemon-reload

for timer in "${TIMERS[@]}"; do
  systemctl enable --now "$timer"
done

echo
echo "Успешно. Расписание:"
systemctl list-timers --all 'getssl-*' 'devbox-*'
echo
echo "Проверить прямо сейчас, не дожидаясь расписания:"
echo "  sudo systemctl start getssl-check.service && systemctl status getssl-check.service"
echo "  sudo systemctl start getssl-renew.service && journalctl -u getssl-renew -n 50"
if [ "$INSTALL_NOTIFY" -eq 1 ]; then
  echo "  sudo $Platform_Deploy_Dir/scripts/notify.sh --test       # проверить канал прямо сейчас"
  echo "  sudo $Platform_Deploy_Dir/scripts/watch-host.sh --dry-run"
fi
if [ "$INSTALL_BACKUP" -eq 1 ]; then
  echo "  sudo $Platform_Deploy_Dir/scripts/backup.sh --dry-run   # план бэкапа, без изменений"
  echo "  sudo systemctl start devbox-backup.service && journalctl -u devbox-backup -n 50"
  echo "  $Platform_Deploy_Dir/scripts/check-backups.sh"
fi
