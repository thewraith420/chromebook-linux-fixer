#!/bin/bash
# nightfall-backups.sh — see the backups Nightfall took, and delete one.
#
#   nightfall-backups.sh list [--tab]        every backup on a mounted drive
#   nightfall-backups.sh delete <dir> <name>
#
# What this deliberately does NOT do is take a backup or restore one. Both
# belong to Nightfall and for the same reason: it holds the real root mounted
# read-only, so nothing is being written while it is read, and a restore can
# overwrite a filesystem nothing is using. Neither is true here. A backup taken
# from the running system would catch databases mid-transaction, and a restore
# would be overwriting the system performing it.
#
# Viewing and deleting are safe from here, and they are the awkward part on the
# tablet: seeing what you have, and freeing space before the next backup. The
# layout is Nightfall's (initramfs/backup-system.sh):
# <drive>/nocturne-backups/<name>.tar with a <name>.info sidecar written only
# after tar succeeds - so an archive without a sidecar is a run that died part
# way, cannot be restored from, and is usually the biggest thing on the drive.
# Those are listed too, marked, because they are exactly what you want to
# delete when space has run out.
set -uo pipefail

SUDO="${FIXER_SUDO:-sudo}"
SUBDIR="${NF_BACKUP_SUBDIR:-nocturne-backups}"

die() { echo "error: $*" >&2; exit 1; }

# Mounted filesystems that could hold backups. NF_BACKUP_DIRS overrides the
# scan for tests. Pseudo filesystems are skipped by type: a whitelist would
# quietly miss whatever the next drive is formatted as.
backup_dirs() {
    if [ -n "${NF_BACKUP_DIRS:-}" ]; then
        local d
        for d in $NF_BACKUP_DIRS; do [ -d "$d" ] && printf '%s\n' "$d"; done
        return
    fi
    # /proc/self/mounts escapes space, tab, newline and backslash as octal;
    # printf %b turns them back, so a drive labelled "My Stick" still works.
    local dev target fstype rest
    while read -r dev target fstype rest; do
        case "$fstype" in
            proc|sysfs|devtmpfs|devpts|tmpfs|ramfs|cgroup|cgroup2|securityfs|\
            pstore|efivarfs|bpf|autofs|mqueue|hugetlbfs|debugfs|tracefs|\
            configfs|fusectl|nsfs|binfmt_misc|rpc_pipefs|squashfs|overlay|\
            selinuxfs|fuse.portal|fuse.gvfsd-fuse) continue ;;
        esac
        target=$(printf '%b' "$target")
        [ -d "$target/$SUBDIR" ] && printf '%s\n' "$target/$SUBDIR"
    done < /proc/self/mounts | sort -u
}

human() {      # bytes -> 86G / 412M / 4.0K
    awk -v b="${1:-0}" 'BEGIN {
        if (b >= 1073741824) printf "%.0fG", b/1073741824
        else if (b >= 1048576) printf "%.0fM", b/1048576
        else if (b >= 1024) printf "%.1fK", b/1024
        else printf "%dB", b
    }'
}

field() {      # field <info file> <name>  -> the value, or empty
    awk -F': *' -v k="$2" '$1 == k { sub(/^[^:]*: */, ""); print; exit }' "$1" 2>/dev/null
}

# One path component, exactly as Nightfall's own scripts require. This is the
# guard that does not depend on anything upstream having sanitised the name.
check_name() {
    case "$1" in
        */*|.|..|"") die "implausible backup name: '$1'" ;;
    esac
}

# Run a mutation with as little privilege as it needs. Files written by
# Nightfall belong to root, but a stick mounted by the desktop is usually
# owned by the user - and asking for a password to delete your own file is a
# bad trade. One escalation either way: pkexec keeps no credential cache.
as_needed() {  # as_needed <dir> <args...>  — script on stdin
    local dir="$1"; shift
    if [ -w "$dir" ]; then bash -s -- "$@"
    else $SUDO bash -s -- "$@"; fi
}

cmd_list() {
    local tab="${1:-}" dir f info name tar bytes created kernel any=0
    for dir in $(backup_dirs); do
        local shown=0
        header() {
            [ "$shown" = 1 ] && return
            shown=1
            printf '%s\n' "$dir"
            df -h "$dir" 2>/dev/null | awk 'NR==2 {printf "  %s free of %s\n", $4, $2}'
        }
        for f in "$dir"/*.tar; do
            [ -f "$f" ] || continue
            name=${f##*/}; name=${name%.tar}
            bytes=$(stat -c %s "$f" 2>/dev/null || echo 0)
            info="$dir/$name.info"
            any=1
            if [ -f "$info" ]; then
                created=$(field "$info" created); kernel=$(field "$info" kernel)
                if [ "$tab" = --tab ]; then
                    printf '%s\t%s\t%s\t%s\t%s\tok\n' "$dir" "$name" "$bytes" \
                           "${created:-unknown}" "${kernel:-unknown}"
                else
                    header
                    printf '  %-34s %6s  %s\n' "$name" "$(human "$bytes")" "${created:-unknown}"
                    [ -n "$kernel" ] && printf '  %-34s        kernel %s\n' "" "$kernel"
                fi
            else
                # No sidecar: Nightfall writes it only after tar succeeds, so
                # this is a run that died part way - power loss, most likely.
                # It cannot be restored from, and Nightfall's own list hides
                # it, which is how it comes to sit there unnoticed.
                if [ "$tab" = --tab ]; then
                    printf '%s\t%s\t%s\t%s\t%s\tincomplete\n' "$dir" "$name" "$bytes" \
                           "never finished" "unknown"
                else
                    header
                    printf '  %-34s %6s  UNFINISHED - cannot be restored from, safe to delete\n' \
                           "$name" "$(human "$bytes")"
                fi
            fi
        done
        [ "$shown" = 1 ] && [ "$tab" != --tab ] && echo
    done
    if [ "$any" = 0 ] && [ "$tab" != --tab ]; then
        echo "No backups found on any mounted drive."
        echo "Nightfall writes them to <drive>/$SUBDIR - plug the drive in, and if"
        echo "the desktop does not mount it automatically, open it in Files first."
    fi
    return 0
}

cmd_delete() {
    local dir="$1" name="$2"
    check_name "$name"
    [ -d "$dir" ] || die "no such backup directory: $dir"
    [ -f "$dir/$name.tar" ] || die "no such backup: $dir/$name.tar"
    local bytes; bytes=$(stat -c %s "$dir/$name.tar" 2>/dev/null || echo 0)
    if [ -f "$dir/$name.info" ]; then
        echo "deleting $name ($(human "$bytes")) from $dir"
    else
        echo "deleting the unfinished $name ($(human "$bytes")) from $dir"
    fi
    as_needed "$dir" "$dir" "$name" <<'ROOT'
set -euo pipefail
dir="$1"; name="$2"
# exFAT and NTFS fall back to read-only on a dirty volume rather than refusing
# to mount, so a write can fail per file under a mount that looked fine.
probe="$dir/.fixer-write-probe"
if ! (: > "$probe") 2>/dev/null; then
    rm -f "$probe" 2>/dev/null || true
    echo "error: $dir is mounted read-only - it may be write-protected or need" >&2
    echo "checking on a computer. Nothing was deleted." >&2
    exit 1
fi
rm -f "$probe" 2>/dev/null || true
rm -f "$dir/$name.tar" || { echo "error: could not delete the archive" >&2; exit 1; }
rm -f "$dir/$name.info" 2>/dev/null || true
sync
ROOT
    local rc=$?
    [ "$rc" = 0 ] && echo "deleted. $(df -h "$dir" 2>/dev/null | awk 'NR==2{print $4}') free on that drive now."
    return "$rc"
}

case "${1:-list}" in
    list)   cmd_list "${2:-}" ;;
    delete) cmd_delete "${2:?usage: $0 delete <dir> <name>}" "${3:?usage: $0 delete <dir> <name>}" ;;
    *) echo "usage: $0 {list [--tab]|delete <dir> <name>}" >&2; exit 2 ;;
esac
