#!/bin/bash
# kernels.sh — the kernels installed on this machine: see them, remove one,
# and choose which one Nightfall boots by default.
#
#   kernels.sh list [--tab]
#   kernels.sh remove <release>
#   kernels.sh default <release>|--clear|--show
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
# GUARDS, in the order they matter - this is the one thing here that can leave
# a machine that will not boot:
#   1. Never the running kernel.
#   2. Never the last one: something has to boot next time.
#   3. It must actually be installed, so a typo fails loudly.
#   4. Nightfall's saved default is cleared if it pointed at this kernel -
#      Nightfall's own remove-kernel.sh does the same, because a stale marker
#      silently stops working with no clue why.
# update-grub runs afterwards, or grub.cfg keeps offering what is gone.
set -uo pipefail

SUDO="${FIXER_SUDO:-sudo}"
BOOT="${FIXER_BOOT_DIR:-/boot}"
MODULES="${FIXER_MODULES_DIR:-/lib/modules}"
NF_DEFAULT_FILE="${NF_DEFAULT_FILE:-$BOOT/nightfall-default}"
GRUB_CFG="${FIXER_GRUB_CFG:-/boot/grub/grub.cfg}"
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
        if [ "$tab" = --tab ]; then
            printf '%s\t%s\t\torphan\tmodules\n' "$r" "$size"
        else
            printf '  %-38s %7s  modules with no kernel - leftovers, safe to remove\n' \
                   "$r" "$(human "$size")"
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
        $SUDO rm -rf "$MODULES/$r" && echo "removed." && return 0
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
        $SUDO bash -s -- "$NF_DEFAULT_FILE" "$path" $pkgs <<'ROOT'
set -euo pipefail
marker="$1"; path="$2"; shift 2
export DEBIAN_FRONTEND=noninteractive
apt-get -y remove --purge "$@"
if [ -f "$marker" ] && [ "$(head -n1 "$marker")" = "$path" -o \
     "$(head -n1 "$marker" | sed 's|.*/vmlinuz-||')" = "${path##*/vmlinuz-}" ]; then
    rm -f "$marker" && echo "cleared Nightfall's saved default (it pointed here)"
fi
sync
ROOT
        return $?
    fi

    # Hand-installed: exactly what a kernel install puts down, mirroring
    # Nightfall's remove-kernel.sh, then update-grub so the menu follows.
    echo "  installed by hand, not owned by any package"
    $SUDO bash -s -- "$BOOT" "$MODULES" "$r" "$NF_DEFAULT_FILE" "$path" <<'ROOT'
set -euo pipefail
boot="$1"; modules="$2"; r="$3"; marker="$4"; path="$5"
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
sync
update-grub || {
    echo "error: update-grub failed AFTER the files were removed - grub.cfg may" >&2
    echo "still list $r. Run 'sudo update-grub' to fix it." >&2; exit 1; }
ROOT
}

case "${1:-list}" in
    list)    cmd_list "${2:-}" ;;
    remove)  cmd_remove "${2:?usage: $0 remove <release>}" ;;
    default) cmd_default "${2:?usage: $0 default <release>|--clear|--show}" ;;
    *) echo "usage: $0 {list [--tab]|remove <release>|default <release>|--clear|--show}" >&2
       exit 2 ;;
esac
