#!/bin/bash
set -euo pipefail

# Escalation is chosen by the caller: plain sudo in a terminal, pkexec
# under the GUI, which has no tty to prompt on.
SUDO="${FIXER_SUDO:-sudo}"
CONFIGS="${WAYDROID_LXC_CONFIGS:-/usr/lib/waydroid/data/configs/config_base /var/lib/waydroid/lxc/waydroid/config}"
CMDLINE_SNAPSHOT="${WAYDROID_CMDLINE_SNAPSHOT:-/var/lib/waydroid/chromebook-fixer-cmdline}"
PROC_CMDLINE="${PROC_CMDLINE:-/proc/cmdline}"

# Two unrelated LXC config bugs share this one fix id and one backup, because
# they live in the same two files (Slate session's call, 2026-09-30).
#
# 1. Waydroid's own LXC template sets "lxc.hook.post-stop = /dev/null".
#    Modern LXC tries to execute that path literally, fails with exit 126,
#    and refuses to restart the container until reboot.
#
# 2. Android inside the container appears to chmod/chown the HOST's real
#    /proc/cmdline (observed going from world-readable to 0440 root:<android
#    uid> the moment Waydroid starts). The fix is containment: bind-mount a
#    private copy over the container's own proc/cmdline so Android's init
#    never touches the real file.
#
#    MUST NOT be read-only. Android's first-stage init does a FATAL
#    CHECKCALL chmod("/proc/cmdline", 0440) while booting; with a read-only
#    bind that chmod gets EROFS, init aborts, and the container dies on
#    startup. Proven on hardware 2026-10-01 (c6f3110 shipped with ",ro," and
#    broke Waydroid on the Slate; dropping it fixed it, and the container's
#    chmod+chown ending up on the SNAPSHOT file instead of the host's real
#    /proc/cmdline is itself the direct confirmation that the bind works).
#    Do not add ",ro" back - that is reintroducing this exact regression.
MOUNT_LINE="lxc.mount.entry = $CMDLINE_SNAPSHOT proc/cmdline none bind,optional,create=file 0 0"

# Recognises only the broken ",ro," form this fix briefly shipped (c6f3110,
# fixed 2026-10-01), so a config carrying it is treated as NEEDING the fix,
# not as already having it - a read-only mount with a healthy-looking line in
# the config is a container that fails to boot, not a working install.
# "ro" only ever appears here, in the options field right after "bind,", so
# this substring is unambiguous for a line this fix itself generated.
is_broken_ro_mount() { grep -qE 'proc/cmdline[[:space:]]+none[[:space:]]+bind,ro,' "$1" 2>/dev/null; }
has_any_cmdline_mount() { grep -qF "proc/cmdline" "$1" 2>/dev/null; }

# Everything that needs root is decided here, unprivileged, and written as a
# plan; ONE escalation then carries it out. pkexec's action is auth_admin,
# not auth_admin_keep - no credential cache, so every separate $SUDO used to
# be another fingerprint prompt (this fix's own apply used to cost up to 8).
PLAN=$(mktemp); trap 'rm -f "$PLAN"' EXIT
CHANGED=0
for f in $CONFIGS; do
    [ -f "$f" ] || continue
    if grep -q "^lxc.hook.post-stop *= */dev/null" "$f"; then
        printf 'hook\t%s\n' "$f" >> "$PLAN"
        echo "will patch $f (post-stop hook)"
        CHANGED=1
    fi
    if is_broken_ro_mount "$f"; then
        printf 'mount-fix\t%s\n' "$f" >> "$PLAN"
        echo "will migrate $f (read-only containment mount -> read-write)"
        CHANGED=1
    elif ! has_any_cmdline_mount "$f"; then
        printf 'mount-add\t%s\n' "$f" >> "$PLAN"
        echo "will contain $f (bind-mounts a private copy over the container's proc/cmdline)"
        CHANGED=1
    fi
done
if [ "$CHANGED" = 0 ] && [ ! -s "$PLAN" ]; then
    echo "nothing to change"
fi

# The snapshot is refreshed whenever anything above touches a config, and
# whenever one already exists from a previous apply - so a reinstall after a
# kernel change picks up the currently running cmdline rather than freezing
# the one from first install. Its content barely matters (nothing here has
# found anything in Waydroid that acts on it beyond being present and
# readable), so a slightly stale copy is not a correctness problem the way a
# stale GRUB entry would be.
REFRESH_SNAPSHOT=0
[ -s "$PLAN" ] && REFRESH_SNAPSHOT=1
[ -e "$CMDLINE_SNAPSHOT" ] && REFRESH_SNAPSHOT=1

$SUDO bash -s -- "$PLAN" "$CMDLINE_SNAPSHOT" "$MOUNT_LINE" "$PROC_CMDLINE" "$REFRESH_SNAPSHOT" <<'ROOT'
set -eu
plan="$1" snapshot="$2" mount_line="$3" proc_cmdline="$4" refresh="$5"

backed_up() { [ -f "$1.chromebook-fixer.orig" ]; }
backup_once() { backed_up "$1" || cp -a "$1" "$1.chromebook-fixer.orig"; }

if [ "$refresh" = 1 ]; then
    mkdir -p "$(dirname "$snapshot")"
    # Root can read /proc/cmdline regardless of its current permission bits
    # (DAC_OVERRIDE) - the 0440-root:<android-uid> state this is working
    # around only blocks unprivileged readers. A placeholder is only for the
    # genuinely exotic case where even this fails (no /proc/cmdline at all).
    # cp into an EXISTING destination rewrites content only and leaves that
    # file's current owner/mode alone (no -p needed, and none wanted) - which
    # matters here because Android's own chmod+chown of the snapshot, once
    # the container has booted once, must survive every later refresh.
    umask 022
    if ! cp "$proc_cmdline" "$snapshot" 2>/dev/null; then
        if [ ! -e "$snapshot" ]; then
            echo "unavailable - see chromebook-fixer waydroid-lxc-hook" > "$snapshot"
        fi
        echo "note: $proc_cmdline could not be read (even as root), so the" \
             "container's private copy is a placeholder rather than a real" \
             "cmdline - reapply later to fix that, if it matters to anything inside"
    fi
fi

while IFS=$'\t' read -r action file; do
    case "$action" in
        hook)
            backup_once "$file"
            sed -i 's|^lxc.hook.post-stop *= */dev/null|lxc.hook.post-stop = /bin/true|' "$file"
            ;;
        mount-add)
            backup_once "$file"
            printf '%s\n' "$mount_line" >> "$file"
            ;;
        mount-fix)
            backup_once "$file"
            # Replace the whole broken line in place (not append+dedupe) -
            # a stray leftover ",ro," line must not survive alongside the
            # fixed one, since LXC honours every lxc.mount.entry it finds and
            # a stale extra bind of the same target is exactly the kind of
            # thing worth not leaving behind on a machine that just had its
            # container fail to boot.
            sed -i "s|^lxc\\.mount\\.entry[[:space:]]*=.*proc/cmdline[[:space:]]\\+none[[:space:]]\\+bind,ro,.*\$|$mount_line|" "$file"
            ;;
    esac
done < "$plan"
ROOT

[ -s "$PLAN" ] || echo "nothing to change (post-stop hook / cmdline containment)"
