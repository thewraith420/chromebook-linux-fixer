#!/bin/bash
# dkms-support.sh — can this machine build out-of-tree kernel modules?
#
#   dkms-support.sh                  exit 0 if ANY installed kernel is buildable
#   dkms-support.sh --kernel <ver>   check one specific kernel
#   dkms-support.sh --list           print every buildable kernel version
#   dkms-support.sh --why            explain, and say what is missing
#
# Deliberately not limited to the running kernel. A custom kernel often ships
# without headers while the distro kernel alongside it has them, and DKMS can
# build for any installed kernel with -k. Reporting "impossible" because the
# kernel you happen to have booted lacks headers would be wrong and unhelpful.

set -uo pipefail

# The major version of the toolchain a kernel was built with, from its own
# config. CONFIG_CLANG_VERSION=190107 means clang 19.1.7, so 190107/10000 = 19.
kconfig_major() {
    local v
    v=$(grep -h "^$2=" "$1" 2>/dev/null | cut -d= -f2)
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
    echo $(( v / 10000 ))
}

# A usable binary for tool $1 at major version $2, or nothing.
#
# Distros ship these versioned: the clang-19 package provides /usr/bin/clang-19
# and no bare "clang" - that name belongs to the "clang" metapackage, which on
# this release is clang 21. So "command -v clang" answers a question nobody
# asked. It is false on a machine carrying exactly the right compiler, and true
# on one whose compiler is two majors adrift of the kernel it would build for.
find_toolchain() {
    local tool="$1" want="${2:-}" got
    if [ -n "$want" ] && command -v "$tool-$want" >/dev/null 2>&1; then
        echo "$tool-$want"; return 0
    fi
    command -v "$tool" >/dev/null 2>&1 || return 1
    [ -n "$want" ] || { echo "$tool"; return 0; }
    got=$("$tool" --version 2>/dev/null \
          | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)
    [ "$got" = "$want" ] && { echo "$tool"; return 0; }
    return 1
}

buildable() {
    local k="$1" b="/lib/modules/$1/build" cfg="/boot/config-$1"
    # -e follows symlinks, which matters: a kernel built elsewhere often leaves
    # build/ pointing at the build machine's source tree, a link that resolves
    # to nothing here. It looks like a headers directory in any listing.
    [ -e "$b" ] || return 1
    # CONFIG_MODVERSIONS kernels need Module.symvers, or symbol CRCs will not
    # match and the module is refused at load.
    if grep -q "^CONFIG_MODVERSIONS=y" "$cfg" 2>/dev/null; then
        [ -e "$b/Module.symvers" ] || return 1
    fi
    # A module must be built by the toolchain that built the kernel it loads
    # into. gcc against a clang/LLD kernel does not merely warn - having
    # headers is not the same as being able to use them, and reporting
    # "buildable" here sends the caller into a build that fails later with
    # something far less obvious than "clang is not installed".
    if grep -q "^CONFIG_CC_IS_CLANG=y" "$cfg" 2>/dev/null; then
        find_toolchain clang "$(kconfig_major "$cfg" CONFIG_CLANG_VERSION)" \
            >/dev/null || return 1
        if grep -q "^CONFIG_LD_IS_LLD=y" "$cfg" 2>/dev/null; then
            find_toolchain ld.lld "$(kconfig_major "$cfg" CONFIG_LLD_VERSION)" \
                >/dev/null || return 1
        fi
    fi
    return 0
}

# What stands between one kernel and a working build, in words.
missing_for() {
    local k="$1" b="/lib/modules/$1/build" cfg="/boot/config-$1"
    if [ ! -e "$b" ]; then
        if [ -L "$b" ]; then
            echo "    build/ points at $(readlink "$b"), which does not exist"
            echo "    on this machine - a leftover from building the kernel elsewhere"
        else
            echo "    no build/ tree (needs the matching linux-headers package;"
            echo "    'make bindeb-pkg' produces one alongside a self-built kernel)"
        fi
        return
    fi
    if grep -q "^CONFIG_MODVERSIONS=y" "$cfg" 2>/dev/null \
       && [ ! -e "$b/Module.symvers" ]; then
        echo "    build/ has no Module.symvers, and this kernel sets"
        echo "    CONFIG_MODVERSIONS - symbol CRCs would not match"
    fi
    local want have
    if grep -q "^CONFIG_CC_IS_CLANG=y" "$cfg" 2>/dev/null; then
        want=$(kconfig_major "$cfg" CONFIG_CLANG_VERSION)
        if ! find_toolchain clang "$want" >/dev/null; then
            echo "    clang-${want:-?}, to match the compiler this kernel was"
            echo "    built with - install: sudo apt install clang-${want:-19}"
            have=$(command -v clang >/dev/null 2>&1 && clang --version 2>/dev/null \
                   | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
            [ -n "$have" ] && {
                echo "    (clang $have is installed, but a different major"
                echo "    builds a module that loads and then misbehaves)"
            }
        fi
    fi
    if grep -q "^CONFIG_LD_IS_LLD=y" "$cfg" 2>/dev/null; then
        want=$(kconfig_major "$cfg" CONFIG_LLD_VERSION)
        find_toolchain ld.lld "$want" >/dev/null || {
            echo "    ld.lld-${want:-?} - this kernel was linked with LLD."
            echo "    Install: sudo apt install lld-${want:-19}"
        }
    fi
}

list_buildable() {
    for k in $(ls /lib/modules/ 2>/dev/null); do
        buildable "$k" && echo "$k"
    done
}

MODE=${1:-}
case "$MODE" in
--kernel)
    K="${2:?usage: $0 --kernel <version>}"
    buildable "$K"; exit $?
    ;;
--list)
    list_buildable
    [ -n "$(list_buildable)" ] || exit 1
    exit 0
    ;;
--why)
    # "--why <kernel>" explains one kernel you are not booted into, which is
    # the case that decides whether booting it is worth the trouble. Handled
    # here rather than below, because the general --why short-circuits on ANY
    # kernel being buildable and would never reach a question about a specific
    # one.
    if [ -n "${2:-}" ]; then
        if buildable "$2"; then
            echo "$2 can build out-of-tree modules."
            exit 0
        fi
        echo "$2 cannot build out-of-tree modules. It needs:"
        missing_for "$2"
        exit 1
    fi
    ;;
esac

mapfile -t OK < <(list_buildable)
HAVE_DKMS=no; command -v dkms >/dev/null 2>&1 && HAVE_DKMS=yes
SIG=$(cat /sys/module/module/parameters/sig_enforce 2>/dev/null || echo N)

RUNNING=$(uname -r)

if [ ${#OK[@]} -gt 0 ] && [ "$HAVE_DKMS" = yes ] && [ "$SIG" != Y ]; then
    [ "$MODE" = --why ] && {
        echo "Out-of-tree module builds are possible."
        printf '  buildable kernel: %s\n' "${OK[@]}"
        # "Possible" is not "possible for the kernel you are on". Saying only
        # the former to someone running a self-built kernel alongside a distro
        # one answers "can I use DKMS?" with yes, when a module built now goes
        # to a kernel they are not booted into and will not load until they
        # are. Name the gap here rather than let it surface at modprobe.
        if ! buildable "$RUNNING"; then
            echo
            echo "  but NOT for the running kernel ($RUNNING)."
            echo "  A module built now would target one of the kernels above and"
            echo "  would not load until you boot it. The running one needs:"
            missing_for "$RUNNING"
        fi
    }
    exit 0
fi

if [ "$MODE" = --why ]; then
    echo "Out-of-tree module builds are not currently possible."
    echo
    if [ ${#OK[@]} -eq 0 ]; then
        echo "  No installed kernel can currently build an out-of-tree module."
        echo
        echo "  running kernel ($RUNNING):"
        missing_for "$RUNNING"
        for k in $(ls /lib/modules/ 2>/dev/null); do
            [ "$k" = "$RUNNING" ] && continue
            echo "  $k:"
            missing_for "$k"
        done
    else
        printf '  buildable kernel: %s\n' "${OK[@]}"
        if ! buildable "$RUNNING"; then
            echo
            echo "  note: the RUNNING kernel ($RUNNING) cannot build, so a"
            echo "        module built now would be for a different kernel and"
            echo "        would not load until you boot into it. It needs:"
            missing_for "$RUNNING"
        fi
    fi
    [ "$HAVE_DKMS" = no ] && echo "  missing: dkms (sudo apt install dkms)"
    [ "$SIG" = Y ] && echo "  missing: module signature enforcement is ON; an unsigned build will not load"
fi
exit 1
