#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

SUDO="${FIXER_SUDO:-sudo}"
BUILD="${XDG_CACHE_HOME:-$HOME/.cache}/chromebook-fixer/cros-fp-fingerprint"

# Pinned so a rebuild is reproducible and the patches keep applying. Bump these
# deliberately, re-testing the patches, rather than tracking a moving branch.
RUSTFP_REPO=https://github.com/ChocolateLoverRaj/rust-fp
RUSTFP_COMMIT=2d0b547
CROSEC_REPO=https://github.com/ChocolateLoverRaj/crosec-rs
CROSEC_COMMIT=b67daa7

[ -e /dev/cros_fp ] || { echo "no /dev/cros_fp on this machine"; exit 1; }

# -- toolchain -------------------------------------------------------------
export PATH="$HOME/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null; then
    echo "This fix builds from source and needs a Rust toolchain."
    echo "Install one for your user (no root, removable with rm -rf ~/.cargo ~/.rustup):"
    echo
    echo "    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal"
    echo
    echo "then re-run this fix."
    exit 1
fi

# -- sources ---------------------------------------------------------------
mkdir -p "$BUILD"
fetch() {   # repo, commit, dir
    if [ -d "$BUILD/$3/.git" ]; then
        git -C "$BUILD/$3" fetch -q --depth 50 origin || true
    else
        git clone -q "$1" "$BUILD/$3"
    fi
    git -C "$BUILD/$3" checkout -q "$2"
    git -C "$BUILD/$3" checkout -q -- .        # drop any previous patching
}
echo "fetching sources..."
fetch "$RUSTFP_REPO" "$RUSTFP_COMMIT" rust-fp
fetch "$CROSEC_REPO" "$CROSEC_COMMIT" crosec-rs

echo "applying fixes..."
git -C "$BUILD/crosec-rs" apply "$FIX_DIR/patches/crosec-chunking-fix.patch"
git -C "$BUILD/rust-fp"   apply "$FIX_DIR/patches/rustfp-upload-retry.patch"

# -- the bridge itself -----------------------------------------------------
mkdir -p "$BUILD/shim/src"
cp "$FIX_DIR/src/"*.rs "$BUILD/shim/src/"
cp "$FIX_DIR/src/Cargo.toml" "$BUILD/shim/Cargo.toml"

echo "building (a few minutes on a slow machine)..."
( cd "$BUILD/shim" && cargo build --release ) || {
    echo "build failed - nothing was installed or changed."
    exit 1
}

BIN="$BUILD/shim/target/release/fprintd-shim"
[ -x "$BIN" ] || { echo "build produced no binary"; exit 1; }

# -- install ---------------------------------------------------------------
$SUDO install -d /usr/local/libexec
$SUDO install -m755 "$BIN" /usr/local/libexec/fprintd-shim

$SUDO tee /etc/systemd/system/fprintd-shim.service >/dev/null <<'UNIT'
[Unit]
Description=fprintd-compatible bridge for the ChromeOS fingerprint MCU
After=dbus.service
Requires=dbus.service

[Service]
Type=simple
ExecStart=/usr/local/libexec/fprintd-shim
Restart=on-failure
RestartSec=2
NoNewPrivileges=yes
ProtectSystem=full
PrivateTmp=yes
DeviceAllow=/dev/cros_fp rw

[Install]
WantedBy=multi-user.target
UNIT

# Only one process may own net.reactivated.Fprint, and fprintd is D-Bus
# activated, so it would race us at every login.
$SUDO systemctl stop fprintd.service 2>/dev/null || true
$SUDO systemctl mask fprintd.service
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now fprintd-shim.service
sleep 3

if ! systemctl is-active --quiet fprintd-shim.service; then
    echo "the service failed to start:"
    systemctl status fprintd-shim.service --no-pager -n 20 || true
    exit 1
fi

echo
echo "running. Enrol a finger with:"
echo "    fprintd-enroll -f right-index-finger \$USER"
echo "or from Settings > System > Users > Fingerprint Login."
echo
echo "Then test:  fprintd-verify \$USER"
