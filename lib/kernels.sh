#!/bin/bash
# kernels.sh — the kernels installed on this machine: see them, remove one,
# and choose which one Nightfall boots by default.
#
#   kernels.sh list [--tab]
#   kernels.sh remove <release>
#   kernels.sh default <release>|--clear|--show
#   kernels.sh install <tarball> [--default]
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
set -uo pipefail

SUDO="${FIXER_SUDO:-sudo}"
BOOT="${FIXER_BOOT_DIR:-/boot}"
MODULES="${FIXER_MODULES_DIR:-/lib/modules}"
NF_DEFAULT_FILE="${NF_DEFAULT_FILE:-$BOOT/nightfall-default}"
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
    install) shift
             tarball="${1:?usage: $0 install <tarball> [--default]}"; shift || true
             set_default=""; [ "${1:-}" = --default ] && set_default=1
             cmd_install "$tarball" "$set_default" ;;
    *) echo "usage: $0 {list [--tab]|remove <release>|default <release>|--clear|--show|install <tarball> [--default]}" >&2
       exit 2 ;;
esac
