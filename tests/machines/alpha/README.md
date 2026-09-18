# alpha

A stackyard machine. The platform is not kept in git -- `./bootstrap` fetches
it at the version recorded in `stackyard.lock`.

## Deploy

```sh
git clone <this repository> /mnt/data/alpha
cd /mnt/data/alpha
./bootstrap                     # platform v0.3.0
cp .env.example .env && $EDITOR .env
cp .env-stacks.example .env-stacks && $EDITOR .env-stacks
sudo ./host-setup
./stack enable <stacks>
```

## Update the platform

From stackyard on your laptop: `./bin/pin.sh <path-to-this-machine>`, commit
here, then on the server `git pull && ./bootstrap && ./stack --check`.
