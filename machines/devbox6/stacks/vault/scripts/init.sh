#!/usr/bin/env bash
#
# Инициализация Vault: выпуск ключей распечатывания и root-токена.
#
# Делается РОВНО ОДИН РАЗ за жизнь хранилища. Повторный запуск отдал бы новый
# комплект ключей от хранилища, которое ими не открывается, поэтому скрипт
# отказывается работать при существующем init.file — а сам файл невосстановим:
# без него запечатанный Vault не открыть никогда.

set -euo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$DIR0/../../.." && pwd )"

# Значения из .env: scripts/config.sh больше нет, источник правды один.
# shellcheck source=../../../scripts/lib-env.sh
. "$ROOT_DIR/scripts/lib-env.sh"
ENV_VARS=(); env_load_files "$ROOT_DIR/.env"

NETWORK="$(env_require Platform_Network 'имя docker-сети, см. .env.example')"
IMAGE=hashicorp/vault
CONF_FILE="$ROOT_DIR/vault/init.file"

if [ -f "$CONF_FILE" ]; then
	echo "Ошибка: $CONF_FILE уже существует — Vault инициализирован." >&2
	echo "  Повторная инициализация выдала бы ключи от другого хранилища." >&2
	exit 1
fi

mkdir -p "$(dirname "$CONF_FILE")"

# Права ставим ДО записи: между созданием файла и chmod он иначе существует
# с умолчаниями umask, а внутри — ключи от всех секретов машины.
umask 077
docker run --rm --network "$NETWORK" "$IMAGE" vault operator init > "$CONF_FILE"
chmod 600 "$CONF_FILE"

echo "Vault инициализирован. Ключи и root-токен: $CONF_FILE"
echo "Файл невосстановим — сделайте копию ВНЕ этой машины прямо сейчас."
