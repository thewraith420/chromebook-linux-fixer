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

# Whether the hardware is here decides whether to INSTALL, not whether the
# source compiles - and "does this still compile" is a question worth asking on
# any machine, including one with no fingerprint reader. Under FIXER_BUILD_ONLY
# the run stops before the install anyway.
if [ -z "${FIXER_BUILD_ONLY:-}" ]; then
    [ -e /dev/cros_fp ] || { echo "no /dev/cros_fp on this machine"; exit 1; }
fi

# -- toolchain -------------------------------------------------------------
# rustup-init is fetched over HTTPS from static.rust-lang.org and checked against
# the .sha256 published beside it before anything runs. Never curl | sh. Installed
# for this user only: no root, nothing outside ~/.cargo and ~/.rustup. Removable
# with `rustup self uninstall`.
install_rust_for_user() {
    local base=https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu
    local tmp want got
    command -v curl >/dev/null || { echo "curl is needed to fetch rustup"; return 1; }
    tmp=$(mktemp -d)
    if ! curl --proto '=https' --tlsv1.2 -sSfL "$base/rustup-init" -o "$tmp/rustup-init" \
       || ! curl --proto '=https' --tlsv1.2 -sSfL "$base/rustup-init.sha256" -o "$tmp/rustup-init.sha256"; then
        echo "could not download rustup from static.rust-lang.org"
        rm -rf "$tmp"; return 1
    fi
    want=$(awk '{print $1; exit}' "$tmp/rustup-init.sha256")
    got=$(sha256sum "$tmp/rustup-init" | cut -d' ' -f1)
    if [ -z "$want" ] || [ "$want" != "$got" ]; then
        echo "rustup-init checksum does not match its published .sha256 - not running it"
        rm -rf "$tmp"; return 1
    fi
    chmod +x "$tmp/rustup-init"
    # --no-modify-path: this script puts ~/.cargo/bin on PATH itself, and the
    # user's shell profile is not ours to edit.
    local rc=0
    "$tmp/rustup-init" -y --profile minimal --no-modify-path || rc=$?
    rm -rf "$tmp"
    return "$rc"
}

export PATH="$HOME/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null; then
    # A build check reaches for neither the network nor an install: a missing
    # toolchain is "cannot tell whether this still builds", which is not the
    # same as "it does not". Same 0/1/2 split the detect scripts use.
    if [ -n "${FIXER_BUILD_ONLY:-}" ]; then
        echo "build-only: no Rust toolchain here, so cannot check the build"
        exit 2
    fi
    echo "This fix builds from source and needs a Rust toolchain."
    echo "Installing one for your user (no root; about 600MB under ~/.rustup)..."
    if ! install_rust_for_user; then
        echo "Rust was not installed. Nothing was changed."
        exit 1
    fi
    export PATH="$HOME/.cargo/bin:$PATH"
    command -v cargo >/dev/null || { echo "rustup ran but cargo is still not on PATH"; exit 1; }
    echo "installed Rust for this user (remove later with: rustup self uninstall)"
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
git -C "$BUILD/crosec-rs" apply "$FIX_DIR/patches/crosec-never-type-fallback.patch"
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

# Build-only: everything above this line is the real build, unprivileged and
# with no effect on the installed system. Stopping here answers "does this
# still compile" without touching anything - which is the question that
# matters after a restore, when every from-source fix has to build again on a
# fresh system and nothing has checked that they still can.
if [ -n "${FIXER_BUILD_ONLY:-}" ]; then
    echo "build-only: compiled $BIN; nothing installed"
    exit 0
fi

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

# -- wake-from-suspend on a touch -------------------------------------------
#
# The sensor's own ACPI/kernel wakeup attributes are already enabled on this
# hardware, but GNOME only arms the sensor while its own unlock dialog is
# actively waiting - it does not stay armed through a whole suspend. This
# hook arms it right before suspend and cleans up right after, so a touch
# while asleep can wake the machine. It relies on the disconnect-cleanup
# above: the hook kills its own armed verify process on resume, and the
# shim releases the claim when that connection drops, so GNOME's own
# lock-screen verify is never left blocked behind it.
$SUDO install -m755 "$FIX_DIR/suspend-hook/chromebook-fp-wake" \
    /usr/lib/systemd/system-sleep/chromebook-fp-wake
echo "installed the wake-on-touch suspend hook"

echo
echo "running. Enrol a finger with:"
echo "    fprintd-enroll -f right-index-finger \$USER"
echo "or from Settings > System > Users > Fingerprint Login."
echo
echo "Then test:  fprintd-verify \$USER"
echo
echo "To test wake-from-suspend: suspend the machine, wait for it to actually"
echo "sleep, then touch the sensor. If it wakes but stays locked, lift your"
echo "finger and touch again once - whether a still-resting finger counts as"
echo "a fresh touch for the lock screen's own verify is hardware-dependent"
echo "and has not been established beyond this one machine."
