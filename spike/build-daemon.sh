#!/bin/bash
# Build ventulusd 5.1.0 on Debian 13 (glibc 2.41), the oldest target, with the
# toolchain the daemon pins. Output: out/ with both binaries and the unit files.
set -euo pipefail

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl git build-essential pkg-config libudev-dev

git clone --depth 1 --branch v5.1.0 https://github.com/Plan-B-Development/ventulusd.git src
cd src
toolchain=$(sed -n 's/^channel = "\(.*\)"/\1/p' rust-toolchain.toml)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain "$toolchain"
# shellcheck disable=SC1091
. "$HOME/.cargo/env"
cargo build --release --locked

mkdir -p ../out
cp target/release/ventulusd target/release/ventulus-tray ../out/
cp packaging/ventulusd.service packaging/ventulus-restore-auto.sh \
    packaging/daemon.toml.example ../out/

echo "::group::binary facts"
./target/release/ventulusd --version
ldd target/release/ventulusd target/release/ventulus-tray
objdump -T target/release/ventulusd | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1
echo "::endgroup::"
