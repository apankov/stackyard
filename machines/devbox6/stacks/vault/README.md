# Стек vault

HashiCorp Vault за общим nginx: TLS терминирует nginx, сам Vault слушает по
HTTP внутри сети `devbox6-net`. Наружу — `https://secrets.12devs.info`.

Раньше это делал `bootstrap-vault.sh`. Его больше нет: установка контейнера
стала обычным `stack.sh enable`, а шаги ниже — те, что остались
интерактивными, потому что требуют человека.

## Первый запуск

```sh
./scripts/stack.sh enable vault          # контейнер + vhost, в правильном порядке
docker ps -a --filter name=vault
```

Проверить запись A для `secrets.12devs.info`, затем выписать сертификат
(заглушку `stack.sh` поставил сам, иначе nginx не стартовал бы):

```sh
cd platform && ./getssl -w ./getssl-config secrets.12devs.info
```

Запускать **из `platform/`**: общий `getssl.cfg` задаёт `ACCOUNT_KEY`
относительно текущего каталога, и из другого места getssl заведёт новый
ACME-аккаунт вместо существующего.

## Инициализация

```sh
./stacks/vault/scripts/init.sh
```

Пишет ключи распечатывания и root-токен в `vault/init.file`. Файл
**невосстановим**: без него запечатанный Vault не открыть никогда. Он
gitignored (`vault/*`), лежит на сервере и только там; копию хранить вне
машины.

Скрипт отказывается работать, если файл уже есть, — повторная инициализация
отдала бы новые ключи от хранилища, которое ими не открывается.

## Azure AD (OIDC)

```sh
./stacks/vault/scripts/oidc-azure-ad.sh
```

Требует интерактивного `vault login` и зашитых в скрипт идентификаторов
приложения. **Секрет клиента Azure лежит в этом файле открытым текстом и в
истории git** — это существующее состояние, а не решение; переносить его в
`stacks/vault/.env` стоит вместе с ротацией самого секрета.

## Проверить

```sh
./scripts/stack.sh --check        # блоки «Upstream'ы» и «vhost'ы nginx»
docker logs vault
curl -sI https://secrets.12devs.info | head -n 1
```
