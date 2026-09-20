#!/bin/bash
set -euo pipefail
SUDO="${FIXER_SUDO:-sudo}"

# One shared cleanup trap for every temp dir this script can create (the
# kernel-fetch's download, and the kernel-reuse copy further down) - `trap
# ... EXIT` REPLACES a previous handler rather than adding to it, so two
# independent `trap 'rm -rf "$X"' EXIT` calls would silently leak whichever
# one set theirs first. Both variables start empty; rm -rf on an empty
# argument is a no-op, not an error, so this is safe before either is ever set.
TMPDIR_FETCH=""; TMPDIR_PICKER=""
trap 'rm -rf "$TMPDIR_FETCH" "$TMPDIR_PICKER"' EXIT

# Where the picker's own source lives. It is a separate project, deliberately:
# this fix installs it, it does not vendor it.
EXPLICIT_REPO="${FIXER_NIGHTFALL_REPO:-${FIXER_PICKER_REPO:-}}"
REPO="$EXPLICIT_REPO"
if [ -z "$REPO" ]; then
    # Renamed project; the old checkout name still exists on machines that
    # cloned before the rename, and GitHub redirects the old URL either way.
    for c in "$HOME/nightfall-boot-manager" "$HOME/buildstuff/nightfall-boot-manager" \
             "$HOME/nocturne-boot-picker" "$HOME/buildstuff/nocturne-boot-picker"; do
        [ -d "$c" ] && { REPO="$c"; break; }
    done
fi
find_installer() {
    local cand
    for cand in install-nightfall.sh install-picker.sh; do
        [ -n "$REPO" ] && [ -x "$REPO/boot-integration/$cand" ] && {
            echo "$REPO/boot-integration/$cand"; return 0; }
    done
    return 1
}
INSTALLER=$(find_installer || true)

# Refuse before touching anything - before the kernel is located or copied,
# before minutes of building - to reinstall from a boot whose command line
# would give Nightfall's entry the wrong panel settings. See
# lib/nightfall-cmdline-check.sh. It used to run after the kernel had already
# been copied out to a temp directory; harmless, but a refusal should mean
# nothing happened, and the Nightfall installer's first version of this same
# guard ran after copying images into /boot. Skipped for a build check, which
# installs nothing and so cannot write a bad entry. The cheapest, most
# side-effect-free check in this whole script, so it runs before either of
# the two auto-provisioning steps below - neither should touch the network or
# $HOME on a run that was always going to refuse here anyway.
if [ -z "${FIXER_BUILD_ONLY:-}" ]; then
    "$FIXER_REPO/lib/nightfall-cmdline-check.sh" || { echo "Nothing was changed."; exit 1; }
fi

# Auto-clone when truly nothing was found - not when $FIXER_NIGHTFALL_REPO was
# given explicitly and turned out wrong, which stays a loud error rather than
# silently cloning somewhere the user did not ask for. Not under a build
# check either: CI should never reach for the network or for sudo on its own.
# Ahead of the kernel check below on purpose, reversing where this sat before:
# a fetched picker kernel is staged inside this checkout
# ($REPO/picker-kernel/vmlinuz, an existing search candidate), so kernel
# auto-fetch needs a resolved $REPO to write into.
NF_CLONE_URL="${NF_CLONE_URL:-https://github.com/thewraith420/nightfall-boot-manager}"
NF_CLONE_DIR="$HOME/nightfall-boot-manager"
if [ -z "$INSTALLER" ] && [ -z "$EXPLICIT_REPO" ] && [ -z "${FIXER_BUILD_ONLY:-}" ]; then
    echo "nightfall-boot-manager checkout not found; cloning it (this fix installs"
    echo "it, it does not vendor it, so this only has to happen once)."
    if ! command -v git >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            echo "  installing git"
            $SUDO apt-get install -y git || {
                echo "could not install git - install it yourself, then re-run:"
                echo "  sudo apt install git"; echo "Nothing was changed."; exit 1; }
        else
            echo "git is not installed and this is not an apt system - install it"
            echo "yourself, then re-run. Nothing was changed."
            exit 1
        fi
    fi
    if git clone "$NF_CLONE_URL" "$NF_CLONE_DIR"; then
        REPO="$NF_CLONE_DIR"
        INSTALLER=$(find_installer || true)
        [ -n "$INSTALLER" ] || {
            echo "cloned $NF_CLONE_DIR but boot-integration/install-nightfall.sh is not"
            echo "in it - wrong branch, or the layout changed. Nothing was changed."
            exit 1; }
    else
        echo "clone failed - no network, or $NF_CLONE_URL is unreachable from here."
    fi
fi

if [ -z "$INSTALLER" ]; then
    echo "nightfall-boot-manager checkout not found (formerly nocturne-boot-picker)."
    echo "Looked in: \$FIXER_NIGHTFALL_REPO, ~/nightfall-boot-manager,"
    echo "           ~/buildstuff/nightfall-boot-manager, and the pre-rename"
    echo "           ~/nocturne-boot-picker paths"
    echo
    echo "  git clone $NF_CLONE_URL"
    echo "  chromebook-fixer apply nightfall"
    echo
    echo "Or point at an existing one:"
    echo "  FIXER_NIGHTFALL_REPO=/path/to/nightfall-boot-manager chromebook-fixer apply nightfall"
    echo "Nothing was changed."
    # No checkout is "cannot check here", not "the source is broken".
    [ -n "${FIXER_BUILD_ONLY:-}" ] && exit 2
    exit 1
fi
echo "picker source: $REPO"

# The picker kernel used to be the one thing this could not produce - building
# one is not something this tool does, and a 1.3GHz tablet is not where you
# would do it. Fetching an ALREADY-BUILT one is a different matter, the same
# category as cloning the checkout above: BobZKernel publishes picker-kernel
# builds as GitHub releases (tag pattern *-picker), so when nothing is found
# locally and the user did not point at a kernel explicitly, the latest one is
# downloaded and staged at $REPO/picker-kernel/vmlinuz - an existing search
# candidate below, so finding it afterward needs no separate code path.
# Under a build check the kernel is irrelevant regardless: it is copied at
# install time, never compiled, and the two things that CAN rot - the LVGL UI
# and the initramfs - build without it. Demanding or fetching it here would
# make the check impossible offline, or on a machine that has never installed
# Nightfall.
KERNEL="${FIXER_NIGHTFALL_KERNEL:-${FIXER_PICKER_KERNEL:-}}"
EXPLICIT_KERNEL="$KERNEL"
if [ -z "$KERNEL" ] && [ -z "${FIXER_BUILD_ONLY:-}" ]; then
    for c in /boot/nightfall/vmlinuz /boot/picker/vmlinuz "$REPO"/picker-kernel/vmlinuz* \
             "$HOME"/buildstuff/BobZKernel/installer-*picker*/boot/vmlinuz-*; do
        [ -r "$c" ] && { KERNEL="$c"; break; }
    done
fi

NF_KERNEL_API="${NF_KERNEL_API:-https://api.github.com/repos/thewraith420/BobZKernel/releases}"
NF_KERNEL_STAGE="$REPO/picker-kernel/vmlinuz"
if [ -z "$KERNEL" ] && [ -z "$EXPLICIT_KERNEL" ] && [ -z "${FIXER_BUILD_ONLY:-}" ]; then
    echo "no picker kernel found locally; checking BobZKernel's releases for one"
    if ! command -v curl >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            echo "  installing curl"
            $SUDO apt-get install -y curl || echo "  could not install curl - skipping the fetch"
        fi
    fi
    if command -v curl >/dev/null 2>&1; then
        # Releases come back newest first, so the first asset whose name says
        # "picker" is the latest picker-kernel build - never the regular
        # daily-driver kernel releases sitting alongside it in the same feed,
        # which is a different BobZKernel branch for a different purpose.
        # || true: under `set -o pipefail`, curl failing (no network, GitHub
        # down, rate-limited) would otherwise make this whole assignment
        # exit non-zero and - under `set -e` - kill the script right here,
        # never reaching the graceful "no picker-kernel release found" /
        # manual-instructions path below. A failed lookup is meant to be a
        # normal, handled outcome, not a crash.
        ASSET_URL=$(curl -fsSL "$NF_KERNEL_API" 2>/dev/null \
            | grep -oE '"browser_download_url": *"[^"]*picker[^"]*"' \
            | head -1 | sed -E 's/.*"(https[^"]*)"/\1/' || true)
        if [ -n "$ASSET_URL" ]; then
            echo "  found $ASSET_URL"
            TMPDIR_FETCH=$(mktemp -d)   # cleaned by the shared trap at the top
            TARBALL="$TMPDIR_FETCH/picker.tar.gz"
            if curl -fSL "$ASSET_URL" -o "$TARBALL" 2>&1 | tail -3; then
                # Exactly one member, by name, straight to its final path -
                # never a blanket extraction. tar -O streams it to stdout and
                # creates nothing else on disk itself, which is a narrower
                # risk surface than letting tar write wherever a member name
                # says to (see lib/kernels.sh install, which extracts a whole
                # tree and needs the traversal guard this does not).
                # || true: an empty match (grep exits 1) under pipefail would
                # otherwise abort the whole script right here instead of
                # reaching the graceful "no boot/vmlinuz-*" message below -
                # same class of bug as $ASSET_URL above.
                MEMBER=$(tar tzf "$TARBALL" 2>/dev/null | grep -E '(^|/)boot/vmlinuz-' | head -1 || true)
                if [ -n "$MEMBER" ]; then
                    mkdir -p "$(dirname "$NF_KERNEL_STAGE")"
                    if tar xzf "$TARBALL" -O "$MEMBER" > "$NF_KERNEL_STAGE" 2>/dev/null \
                       && [ -s "$NF_KERNEL_STAGE" ]; then
                        KERNEL="$NF_KERNEL_STAGE"
                        echo "  staged at $KERNEL"
                    else
                        echo "  extraction failed; not using a partial file"
                        rm -f "$NF_KERNEL_STAGE"
                    fi
                else
                    echo "  no boot/vmlinuz-* inside that release asset"
                fi
            else
                echo "  download failed - no network, or GitHub is unreachable from here"
            fi
        else
            echo "  no picker-kernel release found"
        fi
    fi
fi

if { [ -z "$KERNEL" ] || [ ! -r "$KERNEL" ]; } && [ -z "${FIXER_BUILD_ONLY:-}" ]; then
    echo "No picker kernel image found."
    echo "It is built from BobZKernel's picker-kernel branch, on a real machine,"
    echo "not here, and published as a GitHub release when it is - this looked"
    echo "for one there and found none usable. Point this at one directly:"
    echo "  FIXER_NIGHTFALL_KERNEL=/path/to/vmlinuz chromebook-fixer apply nightfall"
    echo "Nothing was changed."
    exit 1
fi
if [ -n "$KERNEL" ]; then
    echo "picker kernel: $KERNEL"
else
    echo "picker kernel: not needed for a build check"
fi

# Reinstalling (to pick up a rebuilt initramfs) finds the kernel already in
# place, and install-picker.sh copies its argument to exactly that path - cp
# refuses to copy a file onto itself and the whole install aborts partway.
# Hand it a copy instead, so the common "rebuild the initramfs" case works.
KREAL=$([ -n "$KERNEL" ] && readlink -f "$KERNEL" || echo "")
if [ "$KREAL" = /boot/nightfall/vmlinuz ] || [ "$KREAL" = /boot/picker/vmlinuz ]; then
    TMPDIR_PICKER=$(mktemp -d)   # cleaned by the shared trap at the top
    cp "$KERNEL" "$TMPDIR_PICKER/vmlinuz"
    KERNEL="$TMPDIR_PICKER/vmlinuz"
    echo "  (already installed; reusing it via $KERNEL)"
fi

# Everything the UI build and the initramfs build need, checked together and
# installed in one shot - not two, one for each - so a machine missing both
# only prompts for a fingerprint once. Positioned after the kernel-image check
# above: a run about to refuse for lack of a kernel should never ask for
# privilege escalation on its way there. Never under a build check, same
# reasoning as the auto-clone: CI should not reach for sudo on its own, and
# missing tools there already get their own "cannot check" message below.
if [ -z "${FIXER_BUILD_ONLY:-}" ]; then
    MISSING_PKGS=""
    command -v git      >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS git"
    command -v gcc      >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS build-essential"
    command -v make     >/dev/null 2>&1 || case " $MISSING_PKGS " in
        *" build-essential "*) ;; *) MISSING_PKGS="$MISSING_PKGS build-essential" ;; esac
    [ -f "${NF_DRM_HEADER:-/usr/include/libdrm/drm.h}" ] || MISSING_PKGS="$MISSING_PKGS libdrm-dev"
    command -v kexec    >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS kexec-tools"
    command -v busybox  >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS busybox-static"
    command -v cpio     >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS cpio"
    command -v gzip     >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS gzip"
    command -v fakeroot >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS fakeroot"
    command -v e2fsck   >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS e2fsprogs"
    if [ -n "$MISSING_PKGS" ]; then
        if command -v apt-get >/dev/null 2>&1; then
            echo "installing missing build/boot dependencies:$MISSING_PKGS"
            $SUDO apt-get install -y $MISSING_PKGS || {
                echo "could not install:$MISSING_PKGS"
                echo "  sudo apt install$MISSING_PKGS"
                echo "Nothing was changed."
                exit 1
            }
        else
            echo "missing, and this is not an apt system - install yourself:$MISSING_PKGS"
            echo "Nothing was changed."
            exit 1
        fi
    fi
fi

# The UI binary and the initramfs are built HERE on purpose. The initramfs
# bundles this machine's busybox, kexec and the shared libraries the picker
# binary is linked against - one built elsewhere yields a picker that does not
# start, and it fails at boot rather than at install time, on a machine whose
# boot menu needs a keyboard to escape.
if [ ! -x "$REPO/ui/picker" ]; then
    echo "building the touch UI (fetches LVGL on first run)..."
    ( cd "$REPO/ui" && ./fetch-lvgl.sh && make ) || {
        echo
        echo "UI build failed. It needs a compiler and libdrm headers:"
        echo "  sudo apt install build-essential libdrm-dev git"
        echo "Nothing was changed."
        exit 1
    }
fi

# e2fsprogs is a newer requirement than the rest: the initramfs bundles e2fsck
# so Nightfall's Repair menu can check the root filesystem while it is
# unmounted, which is the one moment that check is actually safe to run.
# Under a build check, missing tools mean "cannot check here", not "the source
# is broken" - and build-initramfs.sh exits 1 for both, so ask first. Same
# distinction ipu3-camera makes: a check that reports failure on a machine
# simply lacking kexec is one people stop believing.
if [ -n "${FIXER_BUILD_ONLY:-}" ]; then
    MISSING=""
    for c in busybox cpio gzip fakeroot kexec e2fsck; do
        command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"
    done
    if [ -n "$MISSING" ]; then
        echo "build-only: cannot check the initramfs, missing:$MISSING"
        echo "  sudo apt install busybox-static cpio gzip fakeroot kexec-tools e2fsprogs"
        exit 2
    fi
fi

IMG="$REPO/initramfs/picker-initramfs.img"
echo "building the initramfs (verifies itself at the end)..."
( cd "$REPO/initramfs" && ./build-initramfs.sh "$IMG" ) || {
    echo
    echo "initramfs build failed - see the message above for what was missing."
    echo "Typically: sudo apt install busybox-static cpio gzip fakeroot \\"
    echo "                            kexec-tools e2fsprogs"
    echo "Nothing was changed."
    exit 1
}
[ -r "$IMG" ] || { echo "initramfs was not produced at $IMG"; exit 1; }

# Build-only: the UI and the initramfs are the parts that can rot here -
# Nightfall pins upstream LVGL and its initramfs bundles this machine's
# busybox, kexec, e2fsck and the libraries ui/nightfall links against, any of
# which can move underneath it. Both are built above, unprivileged, and
# build-initramfs.sh verifies its own output. Stop before the install.
if [ -n "${FIXER_BUILD_ONLY:-}" ]; then
    echo "build-only: built $(du -h "$IMG" | cut -f1) initramfs at $IMG;"
    echo "nothing installed and no boot configuration touched"
    exit 0
fi

# One escalation for the whole privileged part. Under the GUI $SUDO is pkexec,
# whose polkit action is auth_admin rather than auth_admin_keep - no credential
# cache, so a second $SUDO is a second password prompt. Everything above this
# line runs unprivileged, which is why it can all happen first.
echo
echo "installing (writes /boot/<picker dir> and one entry in /boot/grub/custom.cfg;"
echo "grub.cfg is NOT regenerated and no existing entry moves)"
if [ -n "${NIGHTFALL_CMDLINE+x}" ]; then
    # sudo resets the environment and pkexec starts from an empty one, so the
    # installer's own NIGHTFALL_CMDLINE lever would silently not arrive and it
    # would fall back to /proc/cmdline - the very thing the variable was set to
    # override. Hand it across explicitly.
    $SUDO env NIGHTFALL_CMDLINE="$NIGHTFALL_CMDLINE" "$INSTALLER" "$KERNEL" "$IMG"
else
    $SUDO "$INSTALLER" "$KERNEL" "$IMG"
fi

echo
# Read the title back out rather than hardcoding it: the installer chooses it,
# and it changed with the rename ('Boot Picker (touch)' -> 'Nightfall (touch)').
# Telling someone to look for an entry that is not in their menu is a bad last
# line for a fix that just rewrote how the machine boots. || true: this is
# cosmetic, so a sed that matches nothing (a menuentry format the installer
# stops using, say) should fall through to an empty title, not kill the
# script's last, purely informational line - same class of bug as $ASSET_URL
# and $MEMBER above.
TITLE=$(sed -n "s/^[[:space:]]*menuentry[[:space:]]*['\"]\([^'\"]*\).*/\1/p" \
        /boot/grub/custom.cfg 2>/dev/null | tail -1 || true)
echo "Reboot and choose ${TITLE:+\'$TITLE\' }from the GRUB menu."
echo "It is not the default: every normal entry still boots exactly as before."
