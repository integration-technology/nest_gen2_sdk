#!/bin/sh
# For SDK maintainers: packages the Nest runtime that install.sh downloads.
#
#   platform/runtime/package_runtime.sh [out_dir]
#
# The bundle unpacks into the install folder (/media/scratch/.nest_gen2_sdk):
#   otp/      Erlang/OTP 26, cross-built for the Nest (ARMv7, musl, OpenSSL 3
#             linked in); see "Building the runtime" in platform/README.md
#   elixir/   Elixir 1.17 (its .beam files, built against a native OTP 26)
#   udhcpc    static BusyBox udhcpc (platform/wifi/build_udhcpc.sh)
#   RUNTIME   what's inside, for the record
#
# Then attach the bundle to a GitHub release of nest_gen2_sdk and update
# RUNTIME_URL and RUNTIME_SHA256 in platform/install.sh.
set -e
NEST_BUILD=${NEST_BUILD:-$HOME/build/nest-repurpose}
OTP=$NEST_BUILD/otp-release-arm-ssl
ELIXIR=$NEST_BUILD/elixir-release
UDHCPC=$NEST_BUILD/udhcpc-arm
OUT=${1:-.}
NAME=nest_gen2-runtime-otp26.2.5.13-elixir1.17.3-armv7-1

for f in "$OTP/bin/erl" "$ELIXIR/bin/elixir" "$UDHCPC"; do
  [ -e "$f" ] || { echo "missing $f"; exit 1; }
done

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -a "$OTP" "$STAGE/otp"
cp -a "$ELIXIR" "$STAGE/elixir"
cp "$UDHCPC" "$STAGE/udhcpc"
chmod 755 "$STAGE/udhcpc"
cat > "$STAGE/RUNTIME" <<EOF
$NAME
Erlang/OTP 26.2.5.13 (Apache-2.0), cross-compiled for arm-nest-linux-musleabi,
  CFLAGS="-O2 -g -march=armv7-a", OpenSSL 3 (Apache-2.0) statically linked.
Elixir 1.17.3 (Apache-2.0).
udhcpc from BusyBox 1.36.1 (GPL-2.0), source:
  https://busybox.net/downloads/busybox-1.36.1.tar.bz2, configured with
  platform/wifi/busybox-udhcpc.config.
EOF

mkdir -p "$OUT"
tar -C "$STAGE" --owner=0 --group=0 -czf "$OUT/$NAME.tar.gz" otp elixir udhcpc RUNTIME
cd "$OUT"
sha256sum "$NAME.tar.gz"
ls -l "$NAME.tar.gz"
