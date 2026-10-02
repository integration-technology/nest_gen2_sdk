#!/bin/sh
# Builds the static udhcpc (BusyBox 1.36.1, udhcpc only) for the Nest.
# BusyBox is GPL-2.0: source from https://busybox.net/downloads/busybox-1.36.1.tar.bz2
# (sha256 b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314).
# Needs the arm-nest-linux-musleabi toolchain on PATH (see ../host_env.sh).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${1:-/tmp/nest-udhcpc}
mkdir -p "$WORK" && cd "$WORK"
[ -f busybox-1.36.1.tar.bz2 ] || curl -sSfLO https://busybox.net/downloads/busybox-1.36.1.tar.bz2
echo "b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314  busybox-1.36.1.tar.bz2" | sha256sum -c -
rm -rf busybox-1.36.1 && tar xjf busybox-1.36.1.tar.bz2 && cd busybox-1.36.1
cp "$HERE/busybox-udhcpc.config" .config
yes "" | make oldconfig >/dev/null
make -j"$(nproc)"
arm-nest-linux-musleabi-strip -o "$WORK/udhcpc" busybox
echo "built $WORK/udhcpc"
