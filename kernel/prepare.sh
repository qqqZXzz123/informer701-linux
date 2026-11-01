#!/bin/bash
set -x
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q build-essential bc bison flex libssl-dev libncurses-dev \
    libelf-dev gcc-arm-linux-gnueabihf binutils-arm-linux-gnueabihf rsync wget python3
arm-linux-gnueabihf-gcc --version | head -1
mkdir -p /tmp/kb/src && cd /tmp/kb/src
if [ ! -f linux-6.6.tar.xz ]; then
    curl -fL --retry 3 -o linux-6.6.tar.xz https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.tar.xz
fi
ls -la linux-6.6.tar.xz
sha256sum linux-6.6.tar.xz
if [ ! -d linux-6.6 ]; then tar xf linux-6.6.tar.xz; fi
echo "=== ГОТОВО: исходники распакованы ==="
ls /tmp/kb/src/linux-6.6 | head
