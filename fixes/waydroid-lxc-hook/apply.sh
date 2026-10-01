#!/bin/bash
set -euo pipefail

# Escalation is chosen by the caller: plain sudo in a terminal, pkexec
# under the GUI, which has no tty to prompt on.
SUDO="${FIXER_SUDO:-sudo}"
CONFIGS="${WAYDROID_LXC_CONFIGS:-/usr/lib/waydroid/data/configs/config_base /var/lib/waydroid/lxc/waydroid/config}"
# Shared across both fixes below: whichever one touches a config file first
# backs it up, so the backup is always the PRE-either-edit state and `revert`
# (a blanket restore of it) undoes both together.
backup_once() { [ -f "$1.chromebook-fixer.orig" ] || $SUDO cp -a "$1" "$1.chromebook-fixer.orig"; }

CHANGED=0
for f in $CONFIGS; do
    [ -f "$f" ] || continue
    grep -q "^lxc.hook.post-stop *= */dev/null" "$f" || continue
    backup_once "$f"
    $SUDO sed -i 's|^lxc.hook.post-stop *= */dev/null|lxc.hook.post-stop = /bin/true|' "$f"
    echo "patched $f"
    CHANGED=1
done
[ "$CHANGED" = 1 ] || echo "nothing to change (post-stop hook)"

# Containment for a second, unrelated bug: Android init inside the container
# appears to chmod/chown the host's /proc/cmdline (observed going from
# world-readable to 0440 root:<android-uid> the moment Waydroid starts; a
# procfs entry's mode lives in a struct shared with the host's mount of the
# same file, so a change made from inside the container's mount namespace can
# leak out). Every unprivileged reader of /proc/cmdline on the host - several
# of this repo's own detect/verify scripts included - breaks once that
# happens, until reboot. The actual fix is to stop the container from ever
# touching the real file at all: bind-mount a private, read-only copy over
# its own proc/cmdline, so whatever Android does to it only ever touches a
# throwaway file in its own mount namespace. Hardening every host-side reader
# is a fallback for machines not yet carrying this, not a substitute for it.
#
# The snapshot is refreshed on every apply, whether or not any config still
# needs the mount line added, so a reinstall after a kernel change picks up
# the currently running cmdline rather than freezing the one from first
# install. Its content barely matters - nothing here has found anything in
# Waydroid that acts on it - so a slightly stale copy is not a correctness
# problem the way a stale GRUB entry would be; readability is what's being
# preserved.
#
# optional: the container must still start if this specific mount fails
# (an older LXC, a renamed snapshot file) - this is containment, not something
# Waydroid depends on to function.
# create=file: proc/cmdline already exists by the time lxc.mount.entry runs
# (LXC's own procfs mount already happened), so this is defensive, not load
# bearing - cheap insurance against a template or LXC version where it does not.
CMDLINE_SNAPSHOT="${WAYDROID_CMDLINE_SNAPSHOT:-/var/lib/waydroid/chromebook-fixer-cmdline}"
MOUNT_LINE="lxc.mount.entry = $CMDLINE_SNAPSHOT proc/cmdline none bind,ro,optional,create=file 0 0"
PROC_CMDLINE="${PROC_CMDLINE:-/proc/cmdline}"

NEED_CONTAINMENT=0
for f in $CONFIGS; do
    [ -f "$f" ] && ! grep -qF "proc/cmdline" "$f" && NEED_CONTAINMENT=1
done

if [ "$NEED_CONTAINMENT" = 1 ] || [ -e "$CMDLINE_SNAPSHOT" ]; then
    $SUDO mkdir -p "$(dirname "$CMDLINE_SNAPSHOT")"
    if [ -r "$PROC_CMDLINE" ]; then
        $SUDO bash -c "umask 022; cp '$PROC_CMDLINE' '$CMDLINE_SNAPSHOT'"
    elif [ ! -e "$CMDLINE_SNAPSHOT" ]; then
        # No snapshot exists yet and the real one cannot be read right now
        # (the bug may already be live on this boot) - write a placeholder
        # rather than leaving the mount target missing. "optional" above means
        # a later apply from a clean boot just overwrites this with the real
        # content; nothing has to be done by hand.
        $SUDO bash -c "umask 022; echo 'unavailable - see chromebook-fixer waydroid-lxc-hook' > '$CMDLINE_SNAPSHOT'"
        echo "note: $PROC_CMDLINE is unreadable right now, so the container's" \
             "private copy is a placeholder rather than a real cmdline -" \
             "reapply from a clean boot to fix that, if it matters to anything inside"
    fi
fi

CONTAINED=0
for f in $CONFIGS; do
    [ -f "$f" ] || continue
    grep -qF "proc/cmdline" "$f" && continue   # already contained in this config
    backup_once "$f"
    printf '%s\n' "$MOUNT_LINE" | $SUDO tee -a "$f" >/dev/null
    echo "contained $f (bind-mounts a private copy over the container's proc/cmdline)"
    CONTAINED=1
done
[ "$CONTAINED" = 1 ] || echo "nothing to change (cmdline containment)"
