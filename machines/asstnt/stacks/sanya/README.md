# Стек `sanya` (bod-assistant-2)

Python/uv + SQLite + Telegram. **Не путать с `sanya-next`** — это разные
проекты с одним смыслом, разными базами и доменами.

## Ротация логов харнесса

Ставится тем же `scripts/systemd.sh`. Таймер `devbox-sanya-logrotate` ежечасно
прогоняет `logrotate` по `${Sanya_Host_Home_Dir}/logs/*.jsonl` и ротирует файл,
переросший 200 МБ (12 сжатых поколений). Путь берётся из `Sanya_Host_Home_Dir`
в `stacks/sanya/.env` — это тот же bind-mount, что видит контейнер как
`/app/logs/events.jsonl`.

Шаблон конфига живёт в репозитории (`stacks/sanya/logrotate/harness.conf.template`), а
установленный экземпляр — в `/etc/sanya/logrotate-harness.conf`, **не** в
`/etc/logrotate.d/`. Иначе те же файлы подхватил бы ещё и системный
`logrotate.timer`, и ротация шла бы дважды по двум независимым state-файлам.
Свой state — `/var/lib/sanya-logrotate/harness.state`.

```bash
sudo logrotate -d --state /var/lib/sanya-logrotate/harness.state \
     /etc/sanya/logrotate-harness.conf          # dry-run, ничего не меняет
sudo systemctl start devbox-sanya-logrotate.service    # прогнать сейчас
journalctl -u devbox-sanya-logrotate -n 20
```

**Зачем.** Приложение пишет `logs/events.jsonl` построчно и не подрезает его
никогда. На залипшей очереди `outbox` (недоставляемые строки ретраятся в цикле)
файл растёт со скоростью около 6 ГБ в сутки — быстрее, чем кончится диск
машины. Ротация здесь ограничитель размера, а не гигиена.

**Почему `copytruncate`.** Харнесс открывает файл заново на каждую строку и не
держит дескриптор, так что штатное переименование он бы тоже пережил.
`copytruncate` выбран как страховка на случай, если логгер станет
буферизованным: писатель с постоянным дескриптором после `rename` молча писал
бы в отвалившийся inode до перезапуска, а после усечения продолжит в тот же
файл. Цена — максимум одна строка, потерянная между копией и усечением.

**Ручная очистка**, если файл уже разросся, — безопасна на живом харнессе, по
той же причине:

```bash
sudo truncate -s 0 /home/ec2-user/dev/bod-assistant-2/logs/events.jsonl
```

