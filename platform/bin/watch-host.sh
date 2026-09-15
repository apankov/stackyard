#!/usr/bin/env bash

# Периодический обход состояния машины: диск, inode, контейнеры.
#
# Юниты systemd сообщают о СВОИХ сбоях через OnFailure, а состояние хоста не
# сообщает о себе никак: кончающееся место и краш-луп контейнера видны только
# тому, кто зашёл посмотреть.
#
# КОД ВОЗВРАТА. 0, если проверки выполнены — независимо от того, что нашли:
# находки скрипт отправляет сам, с деталями. Ненулевой код только если
# проверить не удалось. Иначе OnFailure присылал бы вторым, менее
# информативным сообщением то же самое, о чём мы уже написали.
#
#   sudo ./scripts/watch-host.sh            # обход и оповещения
#   sudo ./scripts/watch-host.sh --dry-run  # показать находки, не отправляя

set -uo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Каталог МАШИНЫ, а не платформы. Обычно его задаёт обёртка в корне машины;
# запасной вариант — на два уровня вверх от platform/bin.
ROOT_DIR="${ROOT_DIR:-$( cd "$DIR0/../.." && pwd )}"
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"

# shellcheck source=scripts/lib-env.sh
. "$LIB_DIR/lib-env.sh"

# Переопределяется только ради тестов: боевой путь — /var/lib/devbox-notify,
# и юниты его не переопределяют. Без этого проверить дедупликацию и
# восстановление можно было бы только от root на живой машине.
STATE_DIR="${DEVBOX_NOTIFY_STATE_DIR:-/var/lib/devbox-notify}"
RESTARTS_STATE="$STATE_DIR/restarts.state"

DRY_RUN=0
[ "${1-}" = "--dry-run" ] && DRY_RUN=1
[ "${1-}" = "--help" ] && { echo "Использование: sudo $0 [--dry-run]"; exit 0; }

die() { echo "Ошибка: $*" >&2; exit 2; }

ENV_NOTIFY="$ROOT_DIR/.env-notify"
[ -f "$ENV_NOTIFY" ] || die "нет $ENV_NOTIFY"
env_load_files "$ROOT_DIR/.env" "$ENV_NOTIFY"

WARN_PCT=$(env_get Notify_Disk_Warn_Percent 80)
CRIT_PCT=$(env_get Notify_Disk_Crit_Percent 90)
MOUNTS=$(env_get Notify_Watch_Mounts /)
RESTART_DELTA=$(env_get Notify_Restart_Delta 3)
IGNORE=$(env_get Notify_Ignore_Containers)

for n in WARN_PCT CRIT_PCT RESTART_DELTA; do
  case "${!n}" in ''|*[!0-9]*) die "$n должно быть целым числом, а не '${!n}'" ;; esac
done

install -d -m 700 "$STATE_DIR" 2>/dev/null || die "не создать $STATE_DIR (нужен root)"

notify() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] notify.sh $*"
    return 0
  fi
  "$DIR0/notify.sh" "$@" || echo "  [!] отправка не удалась: $*" >&2
}

echo "== Обход состояния devbox, $(date -u '+%Y-%m-%d %H:%M') UTC"

# ------------------------------------------------------------------ 1. диск

echo
echo "-- Диск"

# check_usage <ascii-имя> <человеческое имя> <точка> <процент> <детали>
#
# Имя ключа ОТДЕЛЬНО от заголовка и обязательно ASCII: ключ становится именем
# файла состояния, а санитайзер в notify.sh заменяет всё не-ASCII на
# подчёркивания. Два русских слова одинаковой длины дали бы один и тот же файл,
# то есть два разных предупреждения молча гасили бы друг друга.
check_usage() {
  local kind="$1" label="$2" mp="$3" pct="$4" detail="$5"
  # Отдельным оператором, а не шестым присваиванием выше: `local` сначала
  # объявляет ВСЕ имена и лишь потом присваивает, поэтому $kind в той же
  # строке ещё пуст — а под `set -u` это не пустая строка, а смерть скрипта.
  local key="disk-$kind:$mp"

  if [ "$pct" -ge "$CRIT_PCT" ]; then
    printf '  [!!]   %-7s %-10s %s%%\n' "$label" "$mp" "$pct"
    notify --key "$key" --level crit \
           --title "$label на $mp — $pct% (порог $CRIT_PCT%)" <<< "$detail"
  elif [ "$pct" -ge "$WARN_PCT" ]; then
    printf '  [!]    %-7s %-10s %s%%\n' "$label" "$mp" "$pct"
    notify --key "$key" --level warn \
           --title "$label на $mp — $pct% (порог $WARN_PCT%)" <<< "$detail"
  else
    printf '  [ok]   %-7s %-10s %s%%\n' "$label" "$mp" "$pct"
    notify --key "$key" --resolve --title "$label на $mp снова в норме — $pct%"
  fi
}

for mp in $MOUNTS; do
  if ! df -Ph "$mp" >/dev/null 2>&1; then
    echo "  [FAIL] точка монтирования '$mp' недоступна" >&2
    continue
  fi

  pct=$(df -Ph "$mp" | awk 'NR==2 {gsub(/%/, "", $5); print $5}')
  detail=$(df -Ph "$mp" | sed -n '1p;2p')
  # Крупнейшие потребители полезнее в самом сообщении, чем ссылка на команду:
  # тревога приходит ночью, и лишний заход на машину стоит времени.
  detail+=$'\n\n'"крупнейшее в /var/lib/docker:"$'\n'
  detail+=$(docker system df 2>/dev/null | head -5 || echo "  docker не отвечает")
  check_usage space "место" "$mp" "$pct" "$detail"

  ipct=$(df -Pi "$mp" | awk 'NR==2 {gsub(/%/, "", $5); print $5}')
  # На некоторых ФС (btrfs, overlay без своего inode-учёта) df -i возвращает
  # прочерк. Это не отказ — просто нечего проверять.
  case "$ipct" in
    ''|*[!0-9]*) echo "  [--]   inode  $mp           учёт inode недоступен" ;;
    *) check_usage inode "inode" "$mp" "$ipct" "$(df -Pi "$mp" | sed -n '1p;2p')" ;;
  esac
done

# ------------------------------------------------------------ 2. контейнеры

echo
echo "-- Контейнеры"

if ! docker info >/dev/null 2>&1; then
  # Демон не отвечает — это само по себе тревога, и проверить контейнеры мы не
  # можем. Единственное место, где скрипт возвращает ненулевой код.
  notify --key "docker:daemon" --level crit --title "демон docker не отвечает" \
    <<< "$(systemctl status docker --no-pager -n 10 2>&1 | tail -12)"
  die "демон docker не отвечает"
fi
notify --key "docker:daemon" --resolve --title "демон docker снова отвечает"

NEW_RESTARTS=$(mktemp)
trap 'rm -f "$NEW_RESTARTS"' EXIT

while IFS= read -r name; do
  [ -n "$name" ] || continue

  for skip in $IGNORE; do
    [ "$name" = "$skip" ] && continue 2
  done

  read -r state health restarts policy < <(
    docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}} {{.RestartCount}} {{.HostConfig.RestartPolicy.Name}}' \
      "$name" 2>/dev/null
  ) || continue
  [ -n "${state:-}" ] || continue

  echo "$name $restarts" >> "$NEW_RESTARTS"

  # Контейнеры, которым положено завершаться (db-initializer, quotrum-migrate),
  # отсеиваются политикой рестарта, а не списком имён: список пришлось бы
  # править при каждом новом стеке.
  case "$policy" in
    always|unless-stopped) ;;
    *) printf '  [--]   %-22s %s (одноразовый, не наблюдаем)\n' "$name" "$state"; continue ;;
  esac

  # 2a. не запущен
  if [ "$state" != "running" ]; then
    printf '  [!!]   %-22s %s\n' "$name" "$state"
    notify --key "container:$name" --level crit \
           --title "контейнер $name не запущен ($state)" \
           <<< "$(docker logs --tail 25 "$name" 2>&1 | tail -25)"
    continue
  fi
  notify --key "container:$name" --resolve --title "контейнер $name снова запущен"

  # 2b. краш-луп. Следим за ДЕЛЬТОЙ счётчика рестартов, а не за статусом:
  #     `restart: always` показывает «Up 3 seconds» бесконечно, и по docker ps
  #     краш-луп неотличим от нормально работающего контейнера.
  prev=$(awk -v n="$name" '$1 == n {print $2}' "$RESTARTS_STATE" 2>/dev/null)
  case "$prev" in ''|*[!0-9]*) prev="$restarts" ;; esac
  delta=$(( restarts - prev ))

  if [ "$delta" -ge "$RESTART_DELTA" ]; then
    printf '  [!!]   %-22s краш-луп: +%s рестартов\n' "$name" "$delta"
    notify --key "container-loop:$name" --level crit \
           --title "контейнер $name перезапустился $delta раз с прошлой проверки" \
           <<< "$(docker logs --tail 25 "$name" 2>&1 | tail -25)"
  else
    notify --key "container-loop:$name" --resolve --title "контейнер $name перестал перезапускаться"
  fi

  # 2c. healthcheck
  if [ "$health" = "unhealthy" ]; then
    printf '  [!]    %-22s unhealthy\n' "$name"
    notify --key "container-health:$name" --level warn \
           --title "контейнер $name — unhealthy" \
           <<< "$(docker inspect -f '{{range .State.Health.Log}}{{.Output}}{{end}}' "$name" 2>/dev/null | tail -10)"
  else
    notify --key "container-health:$name" --resolve --title "контейнер $name снова healthy"
    printf '  [ok]   %-22s running%s\n' "$name" "$([ "$health" != "-" ] && echo ", $health")"
  fi

done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)

if [ "$DRY_RUN" -eq 0 ]; then
  mv "$NEW_RESTARTS" "$RESTARTS_STATE"
  trap - EXIT
fi

echo
echo "Обход завершён."
