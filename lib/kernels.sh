#!/bin/bash
# kernels.sh — the kernels installed on this machine: see them, remove one,
# and choose which one Nightfall boots by default.
#
#   kernels.sh list [--tab]
#   kernels.sh remove <release>
#   kernels.sh default <release>|--clear|--show
#   kernels.sh install <tarball> [--default]
#   kernels.sh cmdline <release> [--show|--set <full cmdline>|--reset] [--force]
#
# Yes, this is userspace work: a kernel is /boot/vmlinuz-<release>, its
# initrd, its /lib/modules tree and a GRUB entry. The care is in WHICH one and
# WHO owns it.
#
# OWNERSHIP. On this machine some kernels come from apt (linux-image-*) and
# some were built and installed by hand (BobZKernel). Deleting a packaged
# kernel's files behind dpkg's back leaves the package database claiming it is
# installed, so the next upgrade or `apt --fix-broken` can put it back or trip
# over the gap. Packaged kernels therefore go out through apt, unpackaged ones
# by deleting exactly what was installed.
#
# INSTALL. Nightfall's install-kernel.sh does this too, but from initramfs
# with the real root mounted and not in use, via chroot - neither applies here,
# since the fixer runs ON the live system and IS the real root. So this talks
# to depmod/update-initramfs/update-grub directly, no chroot, mirroring what
# both install-kernel.sh (picker) and BobZKernel's own portable install.sh
# (interactive, multi-distro) do at the point they touch disk, but this never
# runs the bundled install.sh - see below. The tarball is BobZKernel's own
# portable installer format: boot/+lib/modules/ alongside VERSION/install.sh/
# uninstall.sh. Only boot/vmlinuz-<release>, boot/{System.map,config}-<release>
# and lib/modules/<release>/ are ever extracted, by exact member name read
# from the tar listing, never a blanket "./boot ./lib". A downloaded tarball
# is not a trusted input the way an initramfs-embedded one implicitly is.
#
# GUARDS, in the order they matter - this is the one thing here that can leave
# a machine that will not boot:
#   1. Never the running kernel.
#   2. Never the last one: something has to boot next time.
#   3. It must actually be installed, so a typo fails loudly.
#   4. Nightfall's saved default is cleared if it pointed at this kernel -
#      Nightfall's own remove-kernel.sh does the same, because a stale marker
#      silently stops working with no clue why.
# update-grub runs afterwards, or grub.cfg keeps offering what is gone.
#
# CMDLINE. /boot/nightfall-cmdline is Nightfall's own per-kernel command-line
# override file, one line per kernel: "<key><TAB><full cmdline>". Its format
# was confirmed with the nightfall-boot-manager session, 2026-10-02, against
# their actual source (apply-cmdline.sh, init) rather than assumed:
#   - A missing line means no override; the row passes through grub.cfg's own
#     entry untouched. There is no separate fallback value - nothing else.
#   - The KEY has no fixed path convention and must be an EXACT STRING MATCH
#     against column 2 of grub.cfg's own "linux" directive for that kernel -
#     apply-cmdline.sh does a plain `$2 in want`, zero normalization. On a
#     machine where /boot is its own partition that is typically a bare
#     /vmlinuz-<release> (no /boot prefix), because GRUB's "root" for that
#     entry IS the boot partition. Never reconstruct this from the release
#     string - always read it from grub.cfg itself, same as cmd_default
#     already does for its own marker, falling back to the computed guess
#     (grub_path) only when grub.cfg has not picked the kernel up yet.
#   - Comments (optional leading whitespace then #) and blank lines are
#     skipped. Duplicate keys: the LAST line wins. An empty value after the
#     tab is never an override, the same as no line at all - to clear one,
#     delete the line outright, never write an empty value.
#   - No locking concern: Nightfall only reads this pre-boot, in its own
#     initramfs, which cannot overlap with this script running on a live,
#     normally-booted OS. Back it up, write it, never touch grub.cfg.
#   - Pruning on removal matches by the stored key's OWN vmlinuz-<release>
#     suffix, not by reconstructing "the" key for the release being removed -
#     grub.cfg may already be stale (or already regenerated) by the time a
#     removal runs, so the file's existing keys are the only reliable source.
#     Orphan detection (an override whose kernel is gone) checks each stored
#     key verbatim as a path, trying it directly and then under $BOOT (a
#     separate-/boot key has no /boot prefix from GRUB's point of view, but
#     this script runs on the live OS, where that partition IS mounted at
#     $BOOT) - same "don't reconstruct, check what's there" principle.
set -uo pipefail

SUDO="${FIXER_SUDO:-sudo}"
BOOT="${FIXER_BOOT_DIR:-/boot}"
MODULES="${FIXER_MODULES_DIR:-/lib/modules}"
NF_DEFAULT_FILE="${NF_DEFAULT_FILE:-$BOOT/nightfall-default}"
NF_CMDLINE_FILE="${NF_CMDLINE_FILE:-$BOOT/nightfall-cmdline}"
GRUB_CFG="${FIXER_GRUB_CFG:-/boot/grub/grub.cfg}"
FIXER_REPO_HINT="${FIXER_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# Where install extracts a tarball's boot/ and lib/ paths onto: always / in
# production, since FIXER_BOOT_DIR/FIXER_MODULES_DIR default to /boot and
# /lib/modules - both already anchored there. Overridable so tests can point
# every one of these at the same fake root without writing to the real one.
INSTALL_ROOT="${FIXER_INSTALL_ROOT:-/}"
RUNNING="${FIXER_RUNNING_KERNEL:-$(uname -r)}"

die() { echo "error: $*" >&2; exit 1; }

releases() {   # every installed kernel, newest-looking last
    local f r
    for f in "$BOOT"/vmlinuz-*; do
        [ -f "$f" ] || continue
        r=${f##*/vmlinuz-}
        printf '%s\n' "$r"
    done | sort -V
}

# Kernel modules with no kernel left. Removing a kernel by hand and forgetting
# the module tree leaves one of these: invisible, and hundreds of megabytes.
orphan_modules() {
    local d r
    for d in "$MODULES"/*/; do
        [ -d "$d" ] || continue
        r=${d%/}; r=${r##*/}
        [ -f "$BOOT/vmlinuz-$r" ] || printf '%s\n' "$r"
    done
}

owner() {      # the package owning a kernel, or empty when hand-installed
    command -v dpkg >/dev/null 2>&1 || return 0
    dpkg -S "$BOOT/vmlinuz-$1" 2>/dev/null | head -1 | cut -d: -f1
}

# Every installed package carrying this release: image, modules, headers. apt
# removing only linux-image-X leaves the modules package behind, which is most
# of the size.
packages_for() {
    command -v dpkg-query >/dev/null 2>&1 || return 0
    dpkg-query -W -f '${Package} ${Status}\n' "*$1*" 2>/dev/null \
        | awk '$NF == "installed" { print $1 }' \
        | grep -E '^linux-' || true
}

# Packages dpkg still has in "removed, config-files remain" state (its own
# `rc` flag) for a release: `apt remove` without --purge leaves these behind,
# and dpkg still considers them the owner of whatever they shipped under
# /lib/modules - including the directory itself, which an orphan-modules
# removal must go through apt for, not delete by hand, or dpkg's own state
# never clears (confirmed real: Software Updater did a bare `apt remove` on
# linux-modules-7.0.0-31-generic, 2026-10-02, leaving exactly this).
rc_packages_for() {
    command -v dpkg-query >/dev/null 2>&1 || return 0
    dpkg-query -W -f '${Package} ${Status}\n' "*$1*" 2>/dev/null \
        | awk '$NF == "config-files" { print $1 }' \
        | grep -E '^linux-' || true
}

bytes_of() {   # total bytes of everything belonging to a release
    local r="$1" total=0 f
    for f in "$BOOT/vmlinuz-$r" "$BOOT/initrd.img-$r" "$BOOT/System.map-$r" \
             "$BOOT/config-$r"; do
        [ -f "$f" ] && total=$((total + $(stat -c %s "$f" 2>/dev/null || echo 0)))
    done
    if [ -d "$MODULES/$r" ]; then
        total=$((total + $(du -sb "$MODULES/$r" 2>/dev/null | cut -f1 || echo 0)))
    fi
    printf '%s' "$total"
}

human() {
    awk -v b="${1:-0}" 'BEGIN {
        if (b >= 1073741824) printf "%.1fG", b/1073741824
        else if (b >= 1048576) printf "%.0fM", b/1048576
        else printf "%.0fK", b/1024
    }'
}

nf_default() { [ -f "$NF_DEFAULT_FILE" ] && head -n1 "$NF_DEFAULT_FILE"; }

# The path GRUB uses for a kernel, which is what Nightfall's marker is compared
# against (initramfs/apply-default.sh matches the linux path from grub.cfg
# exactly). With /boot on its own partition GRUB's paths lose the /boot prefix,
# so this asks rather than assumes.
grub_path() {
    local r="$1"
    if mountpoint -q "$BOOT" 2>/dev/null; then printf '/vmlinuz-%s' "$r"
    else printf '%s/vmlinuz-%s' "$BOOT" "$r"; fi
}

# Any saved cmdline override for a release, matched by the stored key's own
# vmlinuz-<release> suffix (see the CMDLINE note above for why, not an exact
# key). Comments/blank lines skipped, last matching line wins, an empty value
# never counts as an override. World-readable once this script has written
# it (chmod 0644, same as NF_DEFAULT_FILE), so this needs no privilege.
cmdline_for() {
    local release="$1"
    [ -f "$NF_CMDLINE_FILE" ] || return 0
    awk -F'\t' -v suf="vmlinuz-$release" '
        /^[ \t]*#/ { next }
        /^[ \t]*$/ { next }
        $1 ~ (suf "$") { val = ""; for (i = 2; i <= NF; i++) val = val (i > 2 ? "\t" : "") $i }
        END { if (val != "") print val }
    ' "$NF_CMDLINE_FILE"
}

# Every override line whose kernel is gone: the key no longer resolves to a
# real file, checked two ways since a key may or may not carry the /boot
# prefix (see the CMDLINE note above) - directly, then under $BOOT for the
# separate-/boot convention, which has no /boot prefix from GRUB's own point
# of view but needs one here, since this script runs on the live OS where
# that partition is mounted at $BOOT rather than being its own root.
cmdline_orphans() {
    [ -f "$NF_CMDLINE_FILE" ] || return 0
    local key real
    awk -F'\t' '
        /^[ \t]*#/ { next }
        /^[ \t]*$/ { next }
        { print $1 }
    ' "$NF_CMDLINE_FILE" | while IFS= read -r key; do
        [ -n "$key" ] || continue
        # Substitute $BOOT for both conventions before checking, rather than
        # the literal "/boot" prefix (a no-op in production, where BOOT
        # really is /boot, but what makes this testable against a fake one):
        # the same-partition convention writes "/boot/vmlinuz-X" and the
        # separate-/boot one writes a bare "/vmlinuz-X" - either way, BOOT is
        # where this live OS actually has that partition mounted.
        case "$key" in
            /boot/*) real="$BOOT/${key#/boot/}" ;;
            /*)      real="$BOOT$key" ;;
            *)       real="$key" ;;
        esac
        [ -f "$real" ] && continue
        [ -f "$key" ] && continue
        printf '%s\n' "$key"
    done
}

cmd_list() {
    local tab="${1:-}" r pkg size flags def path
    def=$(nf_default)
    for r in $(releases); do
        pkg=$(owner "$r"); size=$(bytes_of "$r"); path=$(grub_path "$r")
        flags=""
        [ "$r" = "$RUNNING" ] && flags="running"
        # By release, not by full path: the marker holds whatever grub.cfg
        # says, and that is /vmlinuz-x with /boot on its own partition and
        # /boot/vmlinuz-x without. The release is unique either way.
        [ -n "$def" ] && [ "${def##*/vmlinuz-}" = "$r" ] && flags="${flags:+$flags,}default"
        [ -f "$BOOT/initrd.img-$r" ] || flags="${flags:+$flags,}no-initrd"
        [ -d "$MODULES/$r" ] || flags="${flags:+$flags,}no-modules"
        [ -n "$(cmdline_for "$r")" ] && flags="${flags:+$flags,}cmdline-override"
        if [ "$tab" = --tab ]; then
            printf '%s\t%s\t%s\t%s\tkernel\n' "$r" "$size" "${pkg:-}" "$flags"
        else
            printf '  %-38s %7s  %s\n' "$r" "$(human "$size")" \
                   "$([ -n "$pkg" ] && echo "$pkg" || echo "installed by hand")"
            [ -n "$flags" ] && printf '  %-38s %7s  %s\n' "" "" "$flags"
        fi
    done
    for r in $(orphan_modules); do
        size=$(du -sb "$MODULES/$r" 2>/dev/null | cut -f1 || echo 0)
        local rc_pkgs; rc_pkgs=$(rc_packages_for "$r")
        if [ "$tab" = --tab ]; then
            printf '%s\t%s\t%s\torphan\tmodules\n' "$r" "$size" "${rc_pkgs//$'\n'/,}"
        elif [ -n "$rc_pkgs" ]; then
            printf '  %-38s %7s  removed but not purged by apt (%s still owns it)\n' \
                   "$r" "$(human "$size")" "$(echo $rc_pkgs | tr '\n' ' ')"
        else
            printf '  %-38s %7s  modules with no kernel - leftovers, safe to remove\n' \
                   "$r" "$(human "$size")"
        fi
    done
    local key
    cmdline_orphans | while IFS= read -r key; do
        if [ "$tab" = --tab ]; then
            printf '%s\t\t\torphan\tcmdline\n' "$key"
        else
            printf '  %-38s %7s  saved cmdline override with no matching kernel: %s\n' \
                   "" "" "$key"
        fi
    done
    return 0
}

cmd_default() {
    local arg="$1"
    if [ "$arg" = --show ]; then
        local d; d=$(nf_default)
        if [ -n "$d" ]; then echo "Nightfall boots this first: $d"
        else echo "No default set; Nightfall boots whatever GRUB lists first."; fi
        return 0
    fi
    if [ "$arg" = --clear ]; then
        [ -f "$NF_DEFAULT_FILE" ] || { echo "no default was set"; return 0; }
        $SUDO rm -f "$NF_DEFAULT_FILE" && echo "cleared; Nightfall boots GRUB's first entry again."
        return $?
    fi
    case "$arg" in */*|"") die "implausible kernel release: '$arg'" ;; esac
    [ -f "$BOOT/vmlinuz-$arg" ] || die "no $BOOT/vmlinuz-$arg - run '$0 list' to see what is installed"
    echo "setting Nightfall's default to $arg"
    # The exact path grub.cfg uses, read inside the privileged block because
    # grub.cfg is root-only. Falls back to the computed path when no entry
    # matches - a kernel GRUB has not picked up yet is still a fair choice,
    # and apply-default.sh treats an unmatched marker as no marker.
    $SUDO bash -s -- "$arg" "$NF_DEFAULT_FILE" "$(grub_path "$arg")" "$GRUB_CFG" <<'ROOT'
set -euo pipefail
release="$1"; marker="$2"; fallback="$3"; cfg="$4"
path=$(awk -v r="vmlinuz-$release" '
    $1 == "linux" && $2 ~ r"$" { print $2; exit }' "$cfg" 2>/dev/null)
printf '%s\n' "${path:-$fallback}" > "$marker"
chmod 0644 "$marker"
echo "  marker: $(cat "$marker")"
ROOT
    echo "takes effect on the next boot through Nightfall."
}

cmd_cmdline() {
    local release="$1"; shift
    case "$release" in */*|"") die "implausible kernel release: '$release'" ;; esac
    [ -f "$BOOT/vmlinuz-$release" ] || die "no $BOOT/vmlinuz-$release - run '$0 list' to see what is installed"

    local action=show value="" force=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --show)   action=show ;;
            --set)    action=set
                      [ $# -ge 2 ] || die "usage: $0 cmdline <release> --set <full cmdline>"
                      value="$2"; shift ;;
            --reset)  action=reset ;;
            --force)  force=1 ;;
            *) die "usage: $0 cmdline <release> [--show|--set <cmdline>|--reset] [--force]" ;;
        esac
        shift
    done

    if [ "$action" = set ]; then
        [ -n "$value" ] || die "refusing to save an empty cmdline"
        case "$value" in *"$(printf '\t')"*) die "cmdline cannot contain a literal tab - the save format is tab-delimited" ;; esac
        case "$value" in *root=*) ;; *) die "refusing to save a cmdline with no root= - the kernel would not know what to mount" ;; esac
    fi

    if [ "$action" = show ]; then
        # Fast, unprivileged path: once saved, an override is a normal
        # world-readable file (0644, same as NF_DEFAULT_FILE) - no need to
        # touch grub.cfg (0600) just to report what is already known.
        local existing; existing=$(cmdline_for "$release")
        if [ -n "$existing" ]; then
            echo "override (saved in $NF_CMDLINE_FILE):"
            echo "  $existing"
            return 0
        fi
        echo "no override saved; reading GRUB's own entry (needs root - grub.cfg is 0600)"
    fi

    $SUDO bash -s -- "$release" "$NF_CMDLINE_FILE" "$GRUB_CFG" "$(grub_path "$release")" \
                      "$action" "$value" "$force" <<'ROOT'
set -euo pipefail
release="$1"; cmdfile="$2"; cfg="$3"; fallback_key="$4"; action="$5"; value="$6"; force="$7"

# The exact grub.cfg key for this release - NOT reconstructed, see the
# CMDLINE note at the top of this script. Falls back to the computed guess
# only when grub.cfg has not picked this kernel up yet (apply-cmdline.sh
# treats an unmatched key as inert, same as apply-default.sh does for the
# default marker, so writing the best guess here is still a fair choice).
key=$(awk -v r="vmlinuz-$release" '
    $1 == "linux" && $2 ~ r"$" { print $2; exit }' "$cfg" 2>/dev/null)
key="${key:-$fallback_key}"

# GRUB's own cmdline for this release - the fallback when no override
# exists, and what a new --set value is compared against for the
# hid_google_hammer guard rail below.
grub_cmdline=$(awk -v r="vmlinuz-$release" '
    $1 == "linux" && $2 ~ r"$" {
        out = ""
        for (i = 3; i <= NF; i++) out = out (i > 3 ? " " : "") $i
        print out
        exit
    }' "$cfg" 2>/dev/null)

# Any existing override, matched by the stored key's own release suffix
# (see cmdline_for() above - duplicated here rather than sourced, since this
# heredoc is its own self-contained script, same as every other privileged
# block in this file).
existing=""
if [ -f "$cmdfile" ]; then
    existing=$(awk -F'\t' -v suf="vmlinuz-$release" '
        /^[ \t]*#/ { next } /^[ \t]*$/ { next }
        $1 ~ (suf "$") { val = ""; for (i = 2; i <= NF; i++) val = val (i > 2 ? "\t" : "") $i }
        END { if (val != "") print val }
    ' "$cmdfile")
fi

case "$action" in
    show)
        if [ -n "$existing" ]; then
            echo "override (saved in $cmdfile):"
            echo "  $existing"
        else
            echo "no override; GRUB's own entry is in effect:"
            echo "  ${grub_cmdline:-<not found in grub.cfg yet>}"
        fi
        ;;
    reset)
        if [ ! -f "$cmdfile" ] || [ -z "$existing" ]; then
            echo "no override was saved for $release; nothing to reset"
            exit 0
        fi
        cp -a "$cmdfile" "$cmdfile.chromebook-fixer.bak"
        awk -F'\t' -v suf="vmlinuz-$release" '
            /^[ \t]*#/ { print; next } /^[ \t]*$/ { print; next }
            $1 ~ (suf "$") { next }
            { print }
        ' "$cmdfile" > "$cmdfile.tmp"
        mv "$cmdfile.tmp" "$cmdfile"
        echo "cleared the override for $release; it falls back to GRUB's own entry:"
        echo "  ${grub_cmdline:-<not found in grub.cfg yet>}"
        ;;
    set)
        # module_blacklist=hid_google_hammer dropped from what is actually in
        # effect right now (the override if one exists, else GRUB's own
        # entry) - confirmed real on this hardware: generic 7.0.0-31 without
        # kernel patch 9206 (the NULL-deref fix) goes dark without it.
        old_cmdline="${existing:-$grub_cmdline}"
        had_hammer=""
        case "$old_cmdline" in *module_blacklist=*hid_google_hammer*) had_hammer=1 ;; esac
        has_hammer=""
        case "$value" in *module_blacklist=*hid_google_hammer*) has_hammer=1 ;; esac
        if [ -n "$had_hammer" ] && [ -z "$has_hammer" ] && [ -z "$force" ]; then
            echo "error: this drops module_blacklist=hid_google_hammer, which the cmdline" >&2
            echo "actually in effect for $release right now carries. On a kernel without patch" >&2
            echo "9206 (the NULL-deref fix) removing it leaves the panel dark - confirmed" >&2
            echo "real on generic 7.0.0-31. Re-run with --force if this kernel definitely" >&2
            echo "has that fix, or keep the blacklist in the new value." >&2
            exit 3
        fi
        mkdir -p "$(dirname "$cmdfile")"
        [ -f "$cmdfile" ] && cp -a "$cmdfile" "$cmdfile.chromebook-fixer.bak"
        if [ -f "$cmdfile" ]; then
            awk -F'\t' -v suf="vmlinuz-$release" '
                /^[ \t]*#/ { print; next } /^[ \t]*$/ { print; next }
                $1 ~ (suf "$") { next }
                { print }
            ' "$cmdfile" > "$cmdfile.tmp"
        else
            : > "$cmdfile.tmp"
        fi
        printf '%s\t%s\n' "$key" "$value" >> "$cmdfile.tmp"
        mv "$cmdfile.tmp" "$cmdfile"
        chmod 0644 "$cmdfile"
        echo "saved override for $release ($key):"
        echo "  $value"
        echo "takes effect on the next boot through Nightfall."
        ;;
esac
ROOT
}

cmd_remove() {
    local r="$1"
    case "$r" in */*|"") die "implausible kernel release: '$r'" ;; esac

    # An orphan module tree is not a kernel: no guards about booting apply,
    # because nothing boots it.
    if [ ! -f "$BOOT/vmlinuz-$r" ]; then
        [ -d "$MODULES/$r" ] || die "no kernel or modules for '$r' - nothing removed"
        [ "$r" = "$RUNNING" ] && die "refusing to touch the running kernel's modules ($r)"
        local size; size=$(du -sb "$MODULES/$r" 2>/dev/null | cut -f1 || echo 0)
        echo "removing leftover modules for $r ($(human "$size")); no kernel is installed for it"
        local rc_pkgs; rc_pkgs=$(rc_packages_for "$r")
        if [ -n "$rc_pkgs" ]; then
            # dpkg still claims this directory (apt remove without --purge):
            # go through apt, or the files come back deleted but dpkg still
            # lists the package in rc state, which a later `apt --fix-broken`
            # or upgrade can act on unpredictably. rm -rf would only make the
            # mismatch between disk and dpkg's database worse, not better.
            echo "  still owned by dpkg (removed, config-files remain): $(echo $rc_pkgs | tr '\n' ' ')"
            echo "  purging those instead of deleting by hand, so dpkg's own state clears too"
            if $SUDO bash -s -- "$NF_CMDLINE_FILE" "$r" $rc_pkgs <<'ROOT'
set -euo pipefail
cmdfile="$1"; r="$2"; shift 2
export DEBIAN_FRONTEND=noninteractive
apt-get -y purge "$@"
if [ -f "$cmdfile" ]; then
    if awk -F'\t' -v suf="vmlinuz-$r" '
        /^[ \t]*#/ { print; next } /^[ \t]*$/ { print; next }
        $1 ~ (suf "$") { removed = 1; next }
        { print }
        END { exit (removed ? 0 : 1) }
    ' "$cmdfile" > "$cmdfile.tmp"; then
        cp -a "$cmdfile" "$cmdfile.chromebook-fixer.bak"
        mv "$cmdfile.tmp" "$cmdfile"
        echo "cleared the saved cmdline override for $r"
    else
        rm -f "$cmdfile.tmp"
    fi
fi
ROOT
            then
                echo "purged."
                return 0
            fi
            return 1
        fi
        if $SUDO bash -s -- "$MODULES/$r" "$NF_CMDLINE_FILE" "$r" <<'ROOT'
set -euo pipefail
modpath="$1"; cmdfile="$2"; r="$3"
rm -rf "$modpath"
if [ -f "$cmdfile" ]; then
    if awk -F'\t' -v suf="vmlinuz-$r" '
        /^[ \t]*#/ { print; next } /^[ \t]*$/ { print; next }
        $1 ~ (suf "$") { removed = 1; next }
        { print }
        END { exit (removed ? 0 : 1) }
    ' "$cmdfile" > "$cmdfile.tmp"; then
        cp -a "$cmdfile" "$cmdfile.chromebook-fixer.bak"
        mv "$cmdfile.tmp" "$cmdfile"
        echo "cleared the saved cmdline override for $r"
    else
        rm -f "$cmdfile.tmp"
    fi
fi
ROOT
        then
            echo "removed."
            return 0
        fi
        return 1
    fi

    [ "$r" = "$RUNNING" ] && die "refusing to remove the running kernel ($r) - boot another one first"
    local count; count=$(releases | wc -l)
    [ "$count" -le 1 ] && die "$r is the only kernel installed - removing it would leave nothing to boot"

    local pkgs size def path
    pkgs=$(packages_for "$r"); size=$(bytes_of "$r")
    def=$(nf_default); path=$(grub_path "$r")
    echo "removing $r ($(human "$size"))"
    [ -n "$def" ] && [ "${def##*/vmlinuz-}" = "$r" ] && \
        echo "  it is Nightfall's saved default; that will be cleared too"

    if [ -n "$pkgs" ]; then
        # Packaged: let apt do it, including the modules and headers packages,
        # and let its hooks run update-grub and update-initramfs.
        echo "  owned by: $(echo $pkgs | tr '\n' ' ')"
        $SUDO bash -s -- "$NF_DEFAULT_FILE" "$NF_CMDLINE_FILE" "$path" "$r" $pkgs <<'ROOT'
set -euo pipefail
marker="$1"; cmdfile="$2"; path="$3"; r="$4"; shift 4
export DEBIAN_FRONTEND=noninteractive
apt-get -y remove --purge "$@"
if [ -f "$marker" ] && [ "$(head -n1 "$marker")" = "$path" -o \
     "$(head -n1 "$marker" | sed 's|.*/vmlinuz-||')" = "${path##*/vmlinuz-}" ]; then
    rm -f "$marker" && echo "cleared Nightfall's saved default (it pointed here)"
fi
if [ -f "$cmdfile" ]; then
    if awk -F'\t' -v suf="vmlinuz-$r" '
        /^[ \t]*#/ { print; next } /^[ \t]*$/ { print; next }
        $1 ~ (suf "$") { removed = 1; next }
        { print }
        END { exit (removed ? 0 : 1) }
    ' "$cmdfile" > "$cmdfile.tmp"; then
        cp -a "$cmdfile" "$cmdfile.chromebook-fixer.bak"
        mv "$cmdfile.tmp" "$cmdfile"
        echo "cleared the saved cmdline override for $r"
    else
        rm -f "$cmdfile.tmp"
    fi
fi
sync
ROOT
        return $?
    fi

    # Hand-installed: exactly what a kernel install puts down, mirroring
    # Nightfall's remove-kernel.sh, then update-grub so the menu follows.
    echo "  installed by hand, not owned by any package"
    $SUDO bash -s -- "$BOOT" "$MODULES" "$r" "$NF_DEFAULT_FILE" "$path" "$NF_CMDLINE_FILE" <<'ROOT'
set -euo pipefail
boot="$1"; modules="$2"; r="$3"; marker="$4"; path="$5"; cmdfile="$6"
# Prove update-grub is there BEFORE deleting anything: learned the hard way in
# Nightfall, where a removal deleted the kernel and then failed at update-grub,
# leaving the files gone and grub.cfg still listing them.
command -v update-grub >/dev/null 2>&1 || {
    echo "error: update-grub is not available; refusing to delete anything" >&2; exit 1; }
for f in "$boot/vmlinuz-$r" "$boot/initrd.img-$r" "$boot/System.map-$r" "$boot/config-$r"; do
    [ -e "$f" ] && rm -f "$f" && echo "  removed $f"
done
[ -d "$modules/$r" ] && rm -rf "$modules/$r" && echo "  removed $modules/$r"
if [ -f "$marker" ] && [ "$(head -n1 "$marker")" = "$path" -o \
     "$(head -n1 "$marker" | sed 's|.*/vmlinuz-||')" = "${path##*/vmlinuz-}" ]; then
    rm -f "$marker" && echo "  cleared Nightfall's saved default (it pointed here)"
fi
if [ -f "$cmdfile" ]; then
    if awk -F'\t' -v suf="vmlinuz-$r" '
        /^[ \t]*#/ { print; next } /^[ \t]*$/ { print; next }
        $1 ~ (suf "$") { removed = 1; next }
        { print }
        END { exit (removed ? 0 : 1) }
    ' "$cmdfile" > "$cmdfile.tmp"; then
        cp -a "$cmdfile" "$cmdfile.chromebook-fixer.bak"
        mv "$cmdfile.tmp" "$cmdfile"
        echo "  cleared the saved cmdline override for $r"
    else
        rm -f "$cmdfile.tmp"
    fi
fi
sync
update-grub || {
    echo "error: update-grub failed AFTER the files were removed - grub.cfg may" >&2
    echo "still list $r. Run 'sudo update-grub' to fix it." >&2; exit 1; }
ROOT
}

cmd_install() {
    local tarball="$1" set_default="${2:-}"
    [ -f "$tarball" ] || die "no such file: $tarball"
    command -v tar >/dev/null 2>&1 || die "tar is not available"

    # The release from boot/vmlinuz-<release> inside the archive, not the
    # filename - the filename is a label, this is what depmod/update-initramfs
    # must be given exactly, and it is what everything below keys on.
    local listing release
    listing=$(tar tzf "$tarball" 2>/dev/null) || die "could not read $tarball - not a gzipped tar?"
    release=$(printf '%s\n' "$listing" | grep -E '(^|/)boot/vmlinuz-' | head -n1 \
              | sed -E 's#.*/boot/vmlinuz-##')
    [ -n "$release" ] || die "no boot/vmlinuz-* inside $tarball - not a kernel tarball?"
    # Tarball-controlled input from here on: refuse a release that would
    # escape /boot or /lib/modules/<release> once substituted into a path.
    case "$release" in */*|.|..|"") die "implausible kernel release inside the archive: '$release'" ;; esac
    echo "kernel release: $release"

    # Exact member names, not a glob against the live filesystem: this listing
    # is the tarball's own idea of what exists, from before anything is
    # trusted. lib/modules/<release>/ is matched as a directory prefix so its
    # whole tree - kernel/, modules.*, the build symlink if present - comes
    # along; nothing else under lib/ or boot/ does.
    local members; members=$(mktemp)
    printf '%s\n' "$listing" | grep -E "(^|/)boot/(vmlinuz|System\.map|config)-${release}\$|(^|/)lib/modules/${release}(/|\$)" \
        > "$members"
    [ -s "$members" ] || { rm -f "$members"; die "found the release name but no matching members - refusing"; }
    # Path-traversal paranoia: nothing here should legitimately need '..' or
    # start with '/', and a tarball is not a trusted input.
    if grep -qE '(^|/)\.\./|^/' "$members"; then
        rm -f "$members"; die "the archive contains an unsafe path for $release - refusing to extract anything"
    fi

    local already=""
    [ -f "$BOOT/vmlinuz-$release" ] && already=1
    local running_now=""
    [ "$release" = "$RUNNING" ] && running_now=1
    if [ -n "$already" ]; then
        echo "note: $release is already installed - reinstalling over it"
    fi
    if [ -n "$running_now" ]; then
        echo "WARNING: this is the kernel currently running. Its modules can be"
        echo "loaded on demand while it runs; overwriting them underneath it is"
        echo "not something an interrupted run can be trusted to leave in a good"
        echo "state. Safer to boot a different kernel first if you can."
    fi

    # A second, collapsed list for the actual extraction. GNU tar recurses a
    # directory member automatically, so ALSO listing that directory's own
    # children makes it go looking for them again once they are already on
    # disk - "Not found in archive", for files that were in fact just
    # written. Sort puts a directory entry before anything nested under it (a
    # prefix always sorts first), then drop any line that falls under a
    # directory already kept; the size math below still uses the uncollapsed
    # $members, since a dropped child's size would otherwise go uncounted.
    local extract_members; extract_members=$(mktemp)
    sort "$members" | awk '
        keep != "" && index($0, keep) == 1 { next }
        { print; if ($0 ~ /\/$/) keep = $0 }
    ' > "$extract_members"

    # Space, before extracting: a kernel + modules tree is hundreds of
    # megabytes, and finding that out 90% through a slow initramfs rebuild
    # wastes minutes and can leave a half-written image. /boot and
    # /lib/modules are not always the same filesystem.
    # -F: members are matched as literal substrings, not patterns - they can
    # contain regex metacharacters (the release string has dots in it), and
    # escaping them for -F would be wrong twice over, since -F never treats
    # its input as regex to begin with. That combination was tried and
    # silently matched nothing, so every install thought it needed 1KB.
    local need_k; need_k=$(awk -F'\t' '{ n=split($0,f," "); sum += f[3] } END { print int(sum/1024)+1 }' \
        <(tar tzvf "$tarball" 2>/dev/null | grep -F -f "$members"))
    local boot_free_k mod_free_k
    boot_free_k=$(df -Pk "$BOOT" 2>/dev/null | awk 'NR==2{print $4}')
    mod_free_k=$(df -Pk "$MODULES" 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "${need_k:-}" ] && [ -n "${boot_free_k:-}" ] && [ -n "${mod_free_k:-}" ]; then
        if [ "$need_k" -gt "$boot_free_k" ] || [ "$need_k" -gt "$mod_free_k" ]; then
            rm -f "$members" "$extract_members"
            die "need about $(human $((need_k * 1024))), but only $(human $((boot_free_k * 1024))) free on $BOOT and $(human $((mod_free_k * 1024))) free on $MODULES"
        fi
    fi

    echo "extracting $release (this takes a moment)"
    local default_path=""
    [ -n "$set_default" ] && default_path=$(grub_path "$release")
    if ! $SUDO bash -s -- "$tarball" "$extract_members" "$BOOT" "$MODULES" "$release" \
                          "$NF_DEFAULT_FILE" "$default_path" "$GRUB_CFG" "$INSTALL_ROOT" <<'ROOT'
set -euo pipefail
tarball="$1"; members="$2"; boot="$3"; modules="$4"; release="$5"
marker="$6"; default_path="$7"; cfg="$8"; install_root="$9"

command -v update-grub >/dev/null 2>&1 || {
    echo "error: update-grub is not available; refusing to extract anything" >&2; exit 1; }

# The archive's own paths (boot/..., lib/modules/...) are already the
# destination layout relative to install_root, same as both existing
# installers (which extract relative to / or a chroot's mount point).
mkdir -p "$install_root"
tar xzf "$tarball" -C "$install_root" -T "$members" || {
    echo "error: extract failed - anything already written is a partial state;" >&2
    echo "re-run this install to overwrite it cleanly." >&2; exit 1; }

[ -f "$boot/vmlinuz-$release" ]      || { echo "error: vmlinuz-$release missing after extract" >&2; exit 1; }
[ -d "$modules/$release" ]           || { echo "error: modules for $release missing after extract" >&2; exit 1; }
sync

echo "depmod $release"
depmod -a "$release" || { echo "error: depmod failed" >&2; exit 1; }

# The slow one - minutes on eMMC. Without this the kernel cannot mount root on
# this hardware (storage/graphics are modules), so a failure here means the
# release must not be reported as installed successfully, even though its
# files are on disk.
echo "update-initramfs -c -k $release (slow - do not power off)"
update-initramfs -c -k "$release" || {
    echo "error: update-initramfs failed - $release is NOT bootable." >&2
    echo "Its files are on disk; other kernels are untouched. Re-run install to try again." >&2
    exit 1; }

echo "update-grub"
update-grub || { echo "error: update-grub failed - $release may not appear in the menu; run 'sudo update-grub'" >&2; exit 1; }

if [ -n "$default_path" ]; then
    path=$(awk -v r="vmlinuz-$release" '$1 == "linux" && $2 ~ r"$" { print $2; exit }' "$cfg" 2>/dev/null)
    printf '%s
' "${path:-$default_path}" > "$marker"
    chmod 0644 "$marker"
    echo "set as Nightfall's default: $(cat "$marker")"
fi

sync
echo "installed $release successfully"
ROOT
    then
        rm -f "$members"
        return 1
    fi
    rm -f "$members"

    echo "it will appear in Nightfall's kernel list on the next boot"
    if command -v dkms >/dev/null 2>&1 && [ -x "$FIXER_REPO_HINT/dkms-support.sh" ]; then
        "$FIXER_REPO_HINT/dkms-support.sh" --kernel "$release" >/dev/null 2>&1 \
            && echo "note: an out-of-tree module here can be built for $release with: sudo dkms autoinstall -k $release" \
            || true
    fi
    [ -z "$set_default" ] && echo "not set as Nightfall's default; see: $0 default $release"
    return 0
}

case "${1:-list}" in
    list)    cmd_list "${2:-}" ;;
    remove)  cmd_remove "${2:?usage: $0 remove <release>}" ;;
    default) cmd_default "${2:?usage: $0 default <release>|--clear|--show}" ;;
    cmdline) release="${2:?usage: $0 cmdline <release> [--show|--set <cmdline>|--reset] [--force]}"
             shift 2 || true
             cmd_cmdline "$release" "$@" ;;
    install) shift
             tarball="${1:?usage: $0 install <tarball> [--default]}"; shift || true
             set_default=""; [ "${1:-}" = --default ] && set_default=1
             cmd_install "$tarball" "$set_default" ;;
    *) echo "usage: $0 {list [--tab]|remove <release>|default <release>|--clear|--show|" \
            "cmdline <release> [--show|--set <cmdline>|--reset] [--force]|" \
            "install <tarball> [--default]}" >&2
       exit 2 ;;
esac
