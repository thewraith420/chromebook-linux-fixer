#!/bin/bash
set -euo pipefail
SUDO="${FIXER_SUDO:-sudo}"

# Where the picker's own source lives. It is a separate project, deliberately:
# this fix installs it, it does not vendor it.
REPO="${FIXER_NIGHTFALL_REPO:-${FIXER_PICKER_REPO:-}}"
if [ -z "$REPO" ]; then
    # Renamed project; the old checkout name still exists on machines that
    # cloned before the rename, and GitHub redirects the old URL either way.
    for c in "$HOME/nightfall-boot-manager" "$HOME/buildstuff/nightfall-boot-manager" \
             "$HOME/nocturne-boot-picker" "$HOME/buildstuff/nocturne-boot-picker"; do
        [ -d "$c" ] && { REPO="$c"; break; }
    done
fi
INSTALLER=
for cand in install-nightfall.sh install-picker.sh; do
    [ -n "$REPO" ] && [ -x "$REPO/boot-integration/$cand" ] && {
        INSTALLER="$REPO/boot-integration/$cand"; break; }
done
if [ -z "$INSTALLER" ]; then
    echo "nightfall-boot-manager checkout not found (formerly nocturne-boot-picker)."
    echo "Looked in: \$FIXER_NIGHTFALL_REPO, ~/nightfall-boot-manager,"
    echo "           ~/buildstuff/nightfall-boot-manager, and the pre-rename"
    echo "           ~/nocturne-boot-picker paths"
    echo
    echo "  git clone https://github.com/thewraith420/nightfall-boot-manager"
    echo "  chromebook-fixer apply nightfall"
    echo
    echo "Or point at an existing one:"
    echo "  FIXER_NIGHTFALL_REPO=/path/to/nightfall-boot-manager chromebook-fixer apply nightfall"
    echo "Nothing was changed."
    exit 1
fi
echo "picker source: $REPO"

# The picker kernel is the one thing this cannot produce. Building a kernel is
# not something this tool does, and a 1.3GHz tablet is not where you would do
# it - so it must already exist somewhere.
KERNEL="${FIXER_NIGHTFALL_KERNEL:-${FIXER_PICKER_KERNEL:-}}"
if [ -z "$KERNEL" ]; then
    for c in /boot/nightfall/vmlinuz /boot/picker/vmlinuz "$REPO"/picker-kernel/vmlinuz* \
             "$HOME"/buildstuff/BobZKernel/installer-*picker*/boot/vmlinuz-*; do
        [ -r "$c" ] && { KERNEL="$c"; break; }
    done
fi
if [ -z "$KERNEL" ] || [ ! -r "$KERNEL" ]; then
    echo "No picker kernel image found."
    echo "It is built from BobZKernel's picker-kernel branch, on a real machine,"
    echo "not here. Point this at the result:"
    echo "  FIXER_NIGHTFALL_KERNEL=/path/to/vmlinuz chromebook-fixer apply nightfall"
    echo "Nothing was changed."
    exit 1
fi
echo "picker kernel: $KERNEL"

# Reinstalling (to pick up a rebuilt initramfs) finds the kernel already in
# place, and install-picker.sh copies its argument to exactly that path - cp
# refuses to copy a file onto itself and the whole install aborts partway.
# Hand it a copy instead, so the common "rebuild the initramfs" case works.
TMPDIR_PICKER=""
KREAL=$(readlink -f "$KERNEL")
if [ "$KREAL" = /boot/nightfall/vmlinuz ] || [ "$KREAL" = /boot/picker/vmlinuz ]; then
    TMPDIR_PICKER=$(mktemp -d)
    trap 'rm -rf "$TMPDIR_PICKER"' EXIT
    cp "$KERNEL" "$TMPDIR_PICKER/vmlinuz"
    KERNEL="$TMPDIR_PICKER/vmlinuz"
    echo "  (already installed; reusing it via $KERNEL)"
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

# One escalation for the whole privileged part. Under the GUI $SUDO is pkexec,
# whose polkit action is auth_admin rather than auth_admin_keep - no credential
# cache, so a second $SUDO is a second password prompt. Everything above this
# line runs unprivileged, which is why it can all happen first.
echo
echo "installing (writes /boot/<picker dir> and one entry in /boot/grub/custom.cfg;"
echo "grub.cfg is NOT regenerated and no existing entry moves)"
$SUDO "$INSTALLER" "$KERNEL" "$IMG"

echo
# Read the title back out rather than hardcoding it: the installer chooses it,
# and it changed with the rename ('Boot Picker (touch)' -> 'Nightfall (touch)').
# Telling someone to look for an entry that is not in their menu is a bad last
# line for a fix that just rewrote how the machine boots.
TITLE=$(sed -n "s/^[[:space:]]*menuentry[[:space:]]*['\"]\([^'\"]*\).*/\1/p" \
        /boot/grub/custom.cfg 2>/dev/null | tail -1)
echo "Reboot and choose ${TITLE:+\'$TITLE\' }from the GRUB menu."
echo "It is not the default: every normal entry still boots exactly as before."
