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
    local k="$1" b="/lib/modules/$1/build"
    [ -e "$b" ] || return 1
    # CONFIG_MODVERSIONS kernels need Module.symvers, or symbol CRCs will not
    # match and the module is refused at load.
    if grep -q "^CONFIG_MODVERSIONS=y" "/boot/config-$k" 2>/dev/null; then
        [ -e "$b/Module.symvers" ] || return 1
    fi
    return 0
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

if [ ${#OK[@]} -gt 0 ] && [ "$HAVE_DKMS" = yes ] && [ "$SIG" != Y ]; then
    [ "$MODE" = --why ] && {
        echo "Out-of-tree module builds are possible."
        printf '  buildable kernel: %s\n' "${OK[@]}"
    }
    exit 0
fi

if [ "$MODE" = --why ]; then
    RUNNING=$(uname -r)
    echo "Out-of-tree module builds are not currently possible."
    echo
    if [ ${#OK[@]} -eq 0 ]; then
        echo "  missing: kernel headers - no installed kernel has a usable build/ tree"
        echo "           (a custom kernel usually needs its linux-headers package"
        echo "            shipping alongside; 'make bindeb-pkg' produces one)"
    else
        printf '  buildable kernel: %s\n' "${OK[@]}"
        if ! buildable "$RUNNING"; then
            echo
            echo "  note: the RUNNING kernel ($RUNNING) has no headers, so a module"
            echo "        built now would be for a different kernel and would not"
            echo "        load until you boot into it."
        fi
    fi
    [ "$HAVE_DKMS" = no ] && echo "  missing: dkms (sudo apt install dkms)"
    [ "$SIG" = Y ] && echo "  missing: module signature enforcement is ON; an unsigned build will not load"
fi
exit 1
