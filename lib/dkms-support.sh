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
        command -v clang >/dev/null 2>&1 || return 1
        if grep -q "^CONFIG_LD_IS_LLD=y" "$cfg" 2>/dev/null; then
            command -v ld.lld >/dev/null 2>&1 || return 1
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
    if grep -q "^CONFIG_CC_IS_CLANG=y" "$cfg" 2>/dev/null \
       && ! command -v clang >/dev/null 2>&1; then
        echo "    clang - this kernel was built with it, and gcc cannot build"
        echo "    loadable modules for a clang-built kernel"
    fi
    if grep -q "^CONFIG_LD_IS_LLD=y" "$cfg" 2>/dev/null \
       && ! command -v ld.lld >/dev/null 2>&1; then
        echo "    ld.lld - this kernel was linked with it"
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
