#!/bin/bash
# Build and install a patched libcamera. Argument: hardware | software
#
# Never selects the hardware ISP on its own - apply.sh decides that, only after
# confirming the ImgU sits in a safe IOMMU domain.
set -euo pipefail

# Escalation is chosen by the caller: plain sudo in a terminal, pkexec
# under the GUI, which has no tty to prompt on.
SUDO="${FIXER_SUDO:-sudo}"

MODE="${1:?usage: build.sh hardware|software}"
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/chromebook-fixer/libcamera"
BACKUP="$WORK/usr-backup"
PATCH="$FIX_DIR/patches/libcamera-ipu3.patch"
JOBS="${FIXER_JOBS:-$(nproc)}"

case "$MODE" in
    hardware) PIPELINES=ipu3,simple,uvcvideo; IPAS=ipu3,simple ;;
    software) PIPELINES=simple,uvcvideo;      IPAS=simple ;;
    *) echo "unknown mode: $MODE"; exit 2 ;;
esac

[ -f "$PATCH" ] || { echo "missing $PATCH"; exit 1; }

# --- build dependencies ------------------------------------------------------
# A fresh install has none of the toolchain. Install it explicitly (an explicit
# list does not depend on deb-src being enabled, which it usually is not).
APT_DEPS="meson ninja-build build-essential pkg-config git curl ca-certificates
          python3-yaml python3-jinja2 python3-ply
          libgnutls28-dev openssl libssl-dev libyaml-dev libudev-dev
          libevent-dev libdrm-dev"

# What is actually missing, asked of the things meson will ask for.
#
# This used to be gated on "is meson, ninja or curl absent" - which does not
# imply anything about the LIBRARIES. A machine with meson installed for some
# other project skipped the dependency install entirely and then failed at
# configure, and until this commit that failure printed nothing at all. Ask
# pkg-config the same questions meson does instead.
missing_build_deps() {
    local miss=""
    for c in meson ninja curl pkg-config; do
        command -v "$c" >/dev/null 2>&1 || miss="$miss $c"
    done
    for m in gnutls libevent_pthreads yaml-0.1 libudev libdrm; do
        pkg-config --exists "$m" 2>/dev/null || miss="$miss $m"
    done
    echo "${miss# }"
}

MISSING=$(missing_build_deps)
if [ -n "$MISSING" ]; then
    if [ -n "${FIXER_BUILD_ONLY:-}" ]; then
        # A build check must not install packages as a side effect of being
        # run, and "deps absent" is not evidence the source is broken - so 2,
        # meaning could-not-check, rather than 1.
        echo "build-only: cannot check, missing build dependencies: $MISSING"
        echo "  sudo apt install $(echo $APT_DEPS)"
        exit 2
    fi
    echo "Installing build tools + libcamera build dependencies..."
    $SUDO apt-get update
    $SUDO apt-get install -y --no-install-recommends $APT_DEPS
fi

mkdir -p "$WORK"
cd "$WORK"

# --- source (pinned v0.7.0 - reproducible on any future Ubuntu) --------------
# The patch is written against libcamera 0.7.0. Rather than fetch "whatever
# libcamera the distro ships now" (which the patch would fail against once
# Ubuntu moves past 0.7.0), pull the exact pristine 0.7.0 tree, archived as a
# release asset and checksum-verified. Cache it in $WORK so re-runs skip the
# download. To reproduce fully offline, drop $LC_TARBALL into $WORK yourself.
LC_TARBALL="libcamera_0.7.0.orig.tar.gz"
LC_URL="https://github.com/thewraith420/chromebook-linux-fixer/releases/download/libcamera-src-0.7.0/$LC_TARBALL"
LC_SHA256="ebd90a3aa2ca87a39323ffb7a4f5bbf72090b43a2431133759620b63e982db87"
if [ ! -d libcamera-src ]; then
    if [ ! -f "$LC_TARBALL" ]; then
        echo "Fetching pinned libcamera 0.7.0 source..."
        curl -fSL -o "$LC_TARBALL" "$LC_URL" \
            || { echo "download failed; place $LC_TARBALL in $WORK and re-run"; exit 1; }
    fi
    echo "$LC_SHA256  $LC_TARBALL" | sha256sum -c - \
        || { echo "source checksum mismatch - refusing to build"; exit 1; }
    rm -rf src-tmp && mkdir src-tmp
    tar -xzf "$LC_TARBALL" -C src-tmp
    DIR=$(find src-tmp -maxdepth 1 -type d -name 'libcamera*' | head -1)
    [ -n "$DIR" ] || { echo "could not find unpacked source"; exit 1; }
    mv "$DIR" libcamera-src && rm -rf src-tmp
fi
cd libcamera-src

# --- patch --------------------------------------------------------------------
# The reverse dry-run only recognises a FULLY applied patch. A partially
# patched tree - what an interrupted build leaves behind - fails it, so the
# forward apply then runs against hunks that are already in, prompts
# "Apply anyway?", and dies. The cache is poisoned from then on and every
# retry fails the same way, which is a miserable thing to meet while
# restoring a machine.
#
# So do not try to reason about the tree's state: if the patch does not apply
# cleanly to it, throw it away and unpack the tarball again. The tarball is
# local and checksummed by this point, so that costs a second and makes the
# whole step idempotent by construction rather than by inspection.
if patch -p1 --dry-run --reverse --force < "$PATCH" >/dev/null 2>&1; then
    echo "Patches already applied."
elif patch -p1 --dry-run --forward --force < "$PATCH" >/dev/null 2>&1; then
    echo "Applying libcamera patches..."
    patch -p1 --forward < "$PATCH" || { echo "patch failed"; exit 1; }
else
    echo "Source tree is not in a state these patches apply to; re-unpacking."
    cd "$WORK"
    rm -rf libcamera-src src-tmp && mkdir src-tmp
    tar -xzf "$LC_TARBALL" -C src-tmp
    DIR=$(find src-tmp -maxdepth 1 -type d -name 'libcamera*' | head -1)
    [ -n "$DIR" ] || { echo "could not find unpacked source"; exit 1; }
    mv "$DIR" libcamera-src && rm -rf src-tmp
    cd libcamera-src
    echo "Applying libcamera patches..."
    patch -p1 --forward < "$PATCH" || { echo "patch failed"; exit 1; }
fi

# --- configure + build --------------------------------------------------------
BUILD="build-$MODE"
echo "Configuring ($MODE ISP: pipelines=$PIPELINES)..."
meson setup "$BUILD" --wipe >/dev/null 2>&1 || true
meson setup "$BUILD" \
    --prefix=/usr --libdir=lib/x86_64-linux-gnu \
    --libexecdir=libexec/x86_64-linux-gnu \
    -Dpipelines="$PIPELINES" -Dipas="$IPAS" \
    -Dcam=enabled -Dv4l2=true \
    -Dgstreamer=disabled -Dqcam=disabled -Dpycamera=disabled \
    -Ddocumentation=disabled -Dtest=false -Dlc-compliance=disabled \
    -Dtracing=disabled -Dwerror=false --buildtype=release \
    >"$WORK/meson-setup.log" 2>&1 || {
        # meson reports on stdout, so ">/dev/null" here used to swallow the
        # reason entirely and set -e exited with no output at all. A configure
        # failure - almost always a missing build dependency - is the most
        # likely way this step fails and was the least explained.
        echo "meson setup failed. Last 20 lines:"
        sed 's/^/    /' "$WORK/meson-setup.log" | tail -20
        echo "  full log: $WORK/meson-setup.log"
        exit 1
    }

echo "Building with $JOBS job(s). This takes 10-30 minutes on this class of CPU..."
ninja -C "$BUILD" -j"$JOBS" >"$WORK/ninja.log" 2>&1 || {
    echo "build failed; nothing was installed. Last 20 lines:"
    sed 's/^/    /' "$WORK/ninja.log" | tail -20
    echo "  full log: $WORK/ninja.log"
    exit 1
}

# Build-only: stop before touching /usr. See the note in
# cros-fp-fingerprint/apply.sh - this exists so a restore can be trusted.
if [ -n "${FIXER_BUILD_ONLY:-}" ]; then
    echo "build-only: built $MODE libcamera in $BUILD; nothing installed"
    exit 0
fi

# --- install ------------------------------------------------------------------
LIBDIR=/usr/lib/x86_64-linux-gnu
LIBEXEC=/usr/libexec/x86_64-linux-gnu/libcamera
declare -a FILES=(
  "$BUILD/src/libcamera/base/libcamera-base.so.0.7.0:$LIBDIR/libcamera-base.so.0.7.0:0644"
  "$BUILD/src/libcamera/libcamera.so.0.7.0:$LIBDIR/libcamera.so.0.7.0:0644"
  "$BUILD/src/ipa/simple/ipa_soft_simple.so:$LIBDIR/libcamera/ipa/ipa_soft_simple.so:0644"
  "$BUILD/src/ipa/simple/ipa_soft_simple.so.sign:$LIBDIR/libcamera/ipa/ipa_soft_simple.so.sign:0644"
  "$BUILD/src/libcamera/proxy/worker/soft_ipa_proxy:$LIBEXEC/soft_ipa_proxy:0755"
  "$BUILD/src/v4l2/v4l2-compat.so:$LIBEXEC/v4l2-compat.so:0644"
  "$BUILD/src/apps/cam/cam:/usr/bin/cam:0755"
)
if [ "$MODE" = hardware ]; then
  FILES+=(
    "$BUILD/src/ipa/ipu3/ipa_ipu3.so:$LIBDIR/libcamera/ipa/ipa_ipu3.so:0644"
    "$BUILD/src/ipa/ipu3/ipa_ipu3.so.sign:$LIBDIR/libcamera/ipa/ipa_ipu3.so.sign:0644"
    "$BUILD/src/libcamera/proxy/worker/ipu3_ipa_proxy:$LIBEXEC/ipu3_ipa_proxy:0755"
  )
fi

echo "Backing up the current install to $BACKUP ..."
for entry in "${FILES[@]}"; do
    dst="${entry#*:}"; dst="${dst%:*}"
    if [ -e "$dst" ]; then
        mkdir -p "$BACKUP$(dirname "$dst")"
        cp -a "$dst" "$BACKUP$dst" 2>/dev/null || \
            $SUDO cp -a "$dst" "$BACKUP$dst"
    fi
done

echo "Installing..."
for entry in "${FILES[@]}"; do
    src="${entry%%:*}"; rest="${entry#*:}"; dst="${rest%:*}"; mode="${rest##*:}"
    [ -s "$src" ] || { echo "missing build output: $src"; exit 1; }
    $SUDO install -o root -g root -m "$mode" "$src" "$dst"
done

# The GPU debayer has no IPU3 unpacking path; force the CPU one so the software
# ISP produces a debayered stream rather than falling back to raw Bayer.
$SUDO mkdir -p /etc/libcamera
$SUDO tee /etc/libcamera/configuration.yaml >/dev/null \
    <<< 'version: 1
configuration:
  software_isp:
    mode: cpu'

$SUDO ldconfig
systemctl --user restart pipewire.socket pipewire wireplumber 2>/dev/null || true
sleep 3
echo "Installed the $MODE ISP path. Backup of the previous install: $BACKUP"
