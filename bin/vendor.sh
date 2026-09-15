#!/usr/bin/env bash
#
# Вендоринг платформы и профиля в машину: заменяет симлинки настоящими копиями
# и записывает, какой именно версией машина пользуется.
#
# Зачем копия, а не симлинк и не submodule. Репозиторий машины обязан быть
# самодостаточным: один `clone` — и всё работает, без доступа ко второму
# репозиторию, без `--recursive`, без забытого коммита указателя. Машины
# уезжают клиентам, и давать клиенту доступ к платформенному репозиторию ради
# того, чтобы у него собирался конфиг, — плохая сделка.
#
# Цена копии: нельзя с одного взгляда понять, правил ли кто-то платформу на
# месте. Поэтому рядом пишется .vendor.lock с версией и контрольными суммами,
# а platform/bin/check-vendor.sh их сверяет. Молча разошедшаяся платформа иначе
# выглядит как исправная.
#
#   ./bin/vendor.sh <машина>            # вендорить платформу и профиль
#   ./bin/vendor.sh <машина> --dry-run  # показать, что изменится
#   ./bin/vendor.sh <машина> --unlink   # вернуть симлинки (режим разработки)

set -euo pipefail

ROOT="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
MACHINE=""; DRY=0; UNLINK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --unlink)  UNLINK=1; shift ;;
    -*) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
    *)  MACHINE="$1"; shift ;;
  esac
done
[ -n "$MACHINE" ] || { echo "Использование: $0 <машина> [--dry-run|--unlink]" >&2; exit 2; }

DEST="$ROOT/machines/$MACHINE"
[ -d "$DEST" ] || { echo "Ошибка: нет машины '$MACHINE'" >&2; exit 2; }

run() { if [ "$DRY" -eq 1 ]; then printf '  [dry] %s\n' "$*"; else "$@"; fi; }

if [ "$UNLINK" -eq 1 ]; then
  for layer in platform profile; do
    src="platform"; [ "$layer" = profile ] && src="profiles"
    run rm -rf "$DEST/$layer"
    run ln -sfn "../../$src" "$DEST/$layer"
  done
  run rm -f "$DEST/.vendor.lock"
  echo "Машина '$MACHINE' переведена в режим разработки: слои подключены симлинками."
  exit 0
fi

# Контрольные суммы считаем ОТ ИСТОЧНИКА и по относительным путям: абсолютные
# зависят от того, где лежит рабочее пространство, и lock перестал бы сходиться
# на другой машине — то есть проверка ломалась бы ровно там, где нужна.
manifest() {
  local dir="$1" prefix="$2"
  ( cd "$dir" && find . -type f -not -name '.DS_Store' | sort \
      | while IFS= read -r f; do printf '%s  %s/%s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$prefix" "${f#./}"; done )
}

echo "== вендоринг в machines/$MACHINE"
for layer in platform profile; do
  src="$ROOT/platform"; [ "$layer" = profile ] && src="$ROOT/profiles"
  ver="$(cat "$src/VERSION" 2>/dev/null || echo '0.0.0-unknown')"
  echo "  $layer: версия $ver"
  run rm -rf "$DEST/$layer"
  run cp -R "$src" "$DEST/$layer"
done

if [ "$DRY" -eq 1 ]; then
  echo "  [dry] .vendor.lock не записан"
  exit 0
fi

{
  echo "# СГЕНЕРИРОВАН bin/vendor.sh — правки будут перезаписаны."
  echo "# Версии слоёв, которыми пользуется эта машина, и суммы их файлов."
  echo "# Сверяет platform/bin/check-vendor.sh: расхождение означает, что слой"
  echo "# правили на месте, и следующее обновление эту правку потеряет."
  echo "platform_version=$(cat "$ROOT/platform/VERSION")"
  echo "profile_version=$(cat "$ROOT/profiles/VERSION")"
  echo "---"
  manifest "$DEST/platform" platform
  manifest "$DEST/profile" profile
} > "$DEST/.vendor.lock"

echo "  .vendor.lock: $(grep -c '^[0-9a-f]' "$DEST/.vendor.lock") файлов"
echo "Готово. Проверить: cd machines/$MACHINE && ./host-setup --check"
