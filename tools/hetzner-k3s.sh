#!/bin/bash

brew install crystal
mkdir -p /tmp/hetzner-k3s
cd /tmp/hetzner-k3s
git clone https://github.com/radekg/hetzner-k3s.git .
git checkout install-software-after-workers
shards install --without-development
crystal build src/hetzner-k3s.cr --release
chmod +x hetzner-k3s
mkdir -p ~/.local/bin
mv -v hetzner-k3s ~/.local/bin/
cd -
rm -rf /tmp/hetzner-k3s