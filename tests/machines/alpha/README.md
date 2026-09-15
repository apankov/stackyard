# alpha

Машина на stackyard. Платформа в git не лежит — её приносит `./bootstrap`
по версии из `stackyard.lock`.

## Развернуть

```sh
git clone <этот репозиторий> /mnt/data/alpha
cd /mnt/data/alpha
./bootstrap                     # платформа v0.3.0
cp .env.example .env && $EDITOR .env
cp .env-stacks.example .env-stacks && $EDITOR .env-stacks
sudo ./host-setup
./stack enable <стеки>
```

## Обновить платформу

Из stackyard на ноутбуке: `./bin/pin.sh <путь-к-этой-машине>`, коммит здесь,
на сервере `git pull && ./bootstrap && ./stack --check`.
