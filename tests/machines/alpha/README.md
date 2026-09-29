# alpha

A stackyard machine. The platform is not kept in git -- `./bootstrap` fetches
it at the version recorded in `stackyard.lock`.

## Deploy

```sh
git clone <this repository> /mnt/data/alpha
cd /mnt/data/alpha
./bootstrap                     # platform v0.3.0
./stack init                    # .env files for the stacks in machine.conf
$EDITOR .env stacks/*/.env
sudo ./host-setup
./stack sync
```

## Update the platform

From stackyard on your laptop: `./bin/pin.sh <path-to-this-machine>`, commit
here, then on the server `git pull && ./bootstrap && ./stack --check`.
