# Стек `sanya-next` — развёртывание

Next.js + Prisma + Postgres + Teams. **Не путать с `sanya`.**

Саня на Next.js 15 + Prisma + Postgres + Microsoft Teams, репозиторий
`internal_ai_automations/sanya`. Домен — `sanya-next.my-new-site.com`.

**Имя не `sanya`, потому что `sanya` уже занято** другим проектом:
`stacks/sanya/compose.yaml` собирает `bod-assistant-2` (Python/uv, SQLite,
Telegram, mem0+Qdrant). Тот же продукт по смыслу, другая реализация по стеку.
Два стека живут рядом: разные контейнеры, разная база, разный домен.

Файлы стека: `stacks/sanya-next/compose.yaml`, `stacks/sanya-next/.env.example`,
`platform/nginx-vhosts/05-sanya-next.my-new-site.com.conf`,
`platform/getssl-config/sanya-next.my-new-site.com/getssl.cfg`, запись в
`stacks/pg/db-init/databases.yaml.example`.

## Порядок

**0. `stacks/sanya-next/.env` — прежде всего остального.** `docker-compose.sh` передаёт
этот файл через `--env-file`, а отсутствующий `--env-file` роняет **любую**
compose-команду на машине, не только эту. То есть без него встанет и sage, и
quotrum.

```bash
cd /home/ec2-user/dev/devbox-asstnt
cp stacks/sanya-next/.env.example stacks/sanya-next/.env && chmod 600 stacks/sanya-next/.env
```

Заполнить обязательное: `SanyaNext_DB_Password` (`openssl rand -base64 32`),
`SanyaNext_Anthropic_API_Key`, `SanyaNext_Operator_AAD_Id`.
`SanyaNext_App_Base_URL` уже проставлен.

**1. База.** Добавить запись в `stacks/pg/db-init/databases.yaml` (файл серверный, в git
его нет — образец в `.example`). Пароль **обязан совпадать** с
`SanyaNext_DB_Password`:

```yaml
- db_name: "sanya_next"
  user: "sanya_next"
  password: "<тот же, что в stacks/sanya-next/.env>"
```

```bash
./docker-compose.sh up -d db-initializer && docker logs db-initializer --tail 20
```

**2. Чекаут приложения.** Каталог называется `sanya`, а стек `sanya-next` —
имя каталога даёт `git clone`, переименовывать его ради имени стека хуже:

```bash
git clone git@gitlab.12devs.com:internal_ai_automations/sanya.git /home/ec2-user/dev/sanya
```

**3. DNS.** A-запись `sanya-next.my-new-site.com` → IP девбокса. Без неё
HTTP-01 валидация getssl не пройдёт, а без сертификата не будет логина: cookie
сессии ставится с флагом `Secure`, по HTTP браузер её выбрасывает молча.

**4. Заглушечный сертификат — до того, как nginx увидит vhost.**
`scripts/certs.sh` сам находит новый vhost по `ssl_certificate_key` и создаёт
самоподписанные пустышки. Без них nginx не стартует с новым конфигом:

```bash
./scripts/certs.sh
```

**5. Образ.** Готовый, из приватного ECR
(`841176798275.dkr.ecr.eu-north-1.amazonaws.com/sanya`). Собирать на девбоксе
нечем: `next build` пикует ~1.3 ГБ, а машина держит 916 МБ (раздел «Сборка падает
по памяти»), и `build:` у сервисов поэтому нет вовсе — иначе compose при
недоступном реестре молча уходил бы в сборку.

```bash
./scripts/registry.sh pin sanya-next     # тег master -> digest в stacks/sanya-next/.env
```

Логин руками не нужен: `docker-compose.sh` делает его сам перед командами,
которые могут потянуть образ (README платформы, «Образы из внешнего реестра»).
Права берутся из IAM-роли инстанса; если `pin` жалуется на токен —
`./scripts/registry.sh --check`.

Запускается стек от **digest'а**, а не от `:master`: с подвижным тегом `up -d`
брал бы локальный слепок и молча расходился с реестром, а откатиться было бы
некуда — под `master` в реестре всегда последнее. Откат — вернуть прежний digest
в `.env` и повторить `up -d`, пока образ есть локально
(`docker images --digests | grep sanya`).

**6. Поднять приложение — ДО перезагрузки nginx.** nginx резолвит upstream'ы
`proxy_pass` при чтении конфига. Если `sanya-next-app` ещё не запущен,
`nginx -s reload` откажется применить конфиг («host not found in upstream»), а
пересозданный контейнер nginx вообще не поднимется — и `restart: always` в
корневом compose превратит это в краш-луп, который уносит **все** vhost'ы
машины, а не только наш. Поэтому строго в этом порядке:

```bash
./docker-compose.sh up -d sanya-next-app sanya-next-cron   # образ подтянется из ECR
docker logs sanya-next-app --tail 30     # должно быть: applying prisma migrations / Applying migration `0_init`
docker ps --filter name=sanya-next       # оба healthy
```

**7. Подключить vhost.** Каталог vhost'ов смонтирован в nginx, пересоздавать
контейнер не нужно:

```bash
docker exec nginx nginx -t && docker exec nginx nginx -s reload
```

**8. Настоящий сертификат.** Именно из `platform/`, а не из корня — причина в разделе
про getssl выше:

```bash
cd platform && ./getssl -w ./getssl-config/ sanya-next.my-new-site.com && cd ..
```

**9. Суперадмин.** Без записи в `admin_users` в админку не войти, и первый
аккаунт не создаёт ни UI, ни агент:

```bash
docker exec sanya-next-app node dist/cli.js create-admin --username admin
```

Пароль печатается один раз, в БД только scrypt-хэш. Повторный запуск с тем же
логином сбрасывает пароль и завершает сессии — это же и «забыл пароль».

**10. Проверить.**

```bash
curl -s https://sanya-next.my-new-site.com/api/health        # {"status":"ok",...}
curl -s https://sanya-next.my-new-site.com/api/health/ready  # {"status":"ready",...}
```

Затем `https://sanya-next.my-new-site.com/login` → логин `admin` и пароль из
шага 9 → дашборд.

**11. Teams — потом.** `SanyaNext_Teams_Enabled=false` на первом деплое, вебхуки
отвечают 503, и это нормально. Включать, когда админка работает; порядок —
`docs/development/deployment.md` §8 в репозитории приложения. Держать
`SanyaNext_Teams_Followup_Only=true`, пока не убедились в качестве ответов: в
этом режиме всё исходящее падает черновиком в `/outbox`.

## Памяти хватает в обрез

Замерено на реальных контейнерах: `sanya-next-app` 133 МБ в покое / 180 МБ под
нагрузкой UI, `sanya-next-cron` 68–79 МБ. Итого ~250 МБ, и это минимум — разбор
транскрипта и agent loop держат в памяти текст и промежуточный JSON.

На машине 916 МБ RAM и ~195 МБ доступно (рядом postgres, nginx, sage, quotrum,
matrix, qdrant и стек `sanya`). Перед запуском стоит посмотреть
`docker stats --no-stream` и решить: swap, остановить неиспользуемые стеки или
увеличить инстанс. Swap для рантайма — подпорка: Node будет свопиться и отвечать
медленно, но не будет убит OOM-killer'ом.

## Два подводных камня

**Пароль базы.** Симптом: контейнер приложения крутится в рестартах и пишет
`Error: P1000, Authentication failed` — пароль в `stacks/sanya-next/.env` не
совпадает с тем, с которым пользователь заведён в общем postgres. Entrypoint
проверяет подключение отдельно от «порт слушает» и печатает ответ Prisma
дословно, иначе такая ошибка выглядит как «схема НЕ совпадает с
prisma/schema.prisma» и уводит отладку в схему.

**Почему образ не собирается здесь.** Это не вкусовое решение и не осторожность:
`FATAL ERROR: Reached heap limit` + `Next.js build worker exited with ... signal:
SIGABRT`. **Swap этого сам не лечит**: V8 выбирает лимит кучи по физической
памяти и про swap не знает.
Замерено — 1 ГБ RAM → лимит 524 МБ, 2 ГБ → 1048 МБ, 4 ГБ → 2096 МБ, а `next build`
проекта пикует около 1.3 ГБ. Лимит задаётся в `Dockerfile` приложения
(`ARG NODE_BUILD_HEAP_MB`, по умолчанию 4096) — это забота той машины, которая
собирает образ для ECR. Если сборку на девбоксе всё же придётся однажды
воспроизвести руками, swap нужен как подпорка под лимит:

```bash
free -h && swapon --show && df -h /var/lib/docker
sudo fallocate -l 4G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=4096
sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

Отличать по сигналу: **SIGABRT** + сообщение V8 = упёрлись в лимит кучи;
**SIGKILL** без сообщения = сработал OOM-killer, не хватило физической памяти.
На девбоксе рядом работают postgres, nginx, sage, quotrum, matrix и qdrant —
свободной памяти на момент сборки заметно меньше, чем всего на машине, поэтому
`free -h` смотреть именно во время сборки. Подробности —
`docs/development/deployment.md` §12 в репозитории приложения.

**Пустое значение в env — это НЕ «не задано» по умолчанию.** `FOO=` попадает в
контейнер как пустая строка, и правило вроде `.min(24)` на ней падает, роняя
валидацию всего env. Внешне это выглядит особенно неприятно: контейнер
**healthy**, `/api/health` и `/login` отдают 200 (они env не импортируют), а
любой рабочий путь — 500, и CLI не запускается. Лечится в приложении
(`emptyStringAsUndefined` в `src/env.ts`), но если увидите такую картину —
смотрите не логи nginx, а `docker exec sanya-next-app node dist/cli.js --help`:
он покажет, какая именно переменная не прошла.

## Обновление и откат

Бэкап перед апгрейдом. Скрипты живут в чекауте приложения и параметризованы —
на девбоксе общий контейнер `postgres`, а не свой:

```bash
cd /home/ec2-user/dev/sanya
CONTAINER=postgres POSTGRES_USER=sanya_next POSTGRES_DB=sanya_next ./scripts/db-backup.sh
CONTAINER=postgres POSTGRES_USER=sanya_next POSTGRES_DB=sanya_next \
  ./scripts/db-restore.sh --check backups/<свежий>.sql.gz

# новый образ из ECR
cd /home/ec2-user/dev/devbox-asstnt
grep '^SanyaNext_Image_Digest=' stacks/sanya-next/.env    # ЗАПИСАТЬ: это точка отката
./scripts/registry.sh pin sanya-next                      # master -> digest
./docker-compose.sh up -d sanya-next-app sanya-next-cron
docker logs sanya-next-app --tail 30      # миграции применились?
```

Откат: сначала код (вернуть записанный digest в `stacks/sanya-next/.env` и
`up -d`), потом данные (`db-restore.sh --apply`). Наоборот — старая схема
встретится с новым кодом. Образ под прежним digest'ом должен ещё лежать локально
(`docker images --digests | grep sanya`) либо оставаться в реестре — за вторым
следит `./scripts/registry.sh --check`.

Полный runbook приложения (включая процедуру восстановления и раздел «если не
работает») — `docs/development/deployment.md` в репозитории `sanya`.
