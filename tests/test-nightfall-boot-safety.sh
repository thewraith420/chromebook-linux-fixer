#!/bin/bash
# The checks that stand between a fixer action and a Nightfall boot entry that
# comes up dark - tested against fake /proc/cmdline and custom.cfg files, so
# the result never depends on which machine runs it.
#
#   tests/test-nightfall-boot-safety.sh          run everything
#   CHECK=/path/to/copy tests/...                run against a modified check
#                                                (how the break-checks work)
#
# Every refusal rule has at least one case where it is the ONLY rule that
# refuses. Without that, deleting the rule passes the suite: an earlier version
# of this matrix had every recovery case also carry no i915 options against an
# entry that had some, so the "no options while the entry has some" rule refused
# them first and the nomodeset/recovery word check was never exercised on its
# own. The Nightfall session found the same shape in its own installer tests.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${CHECK:-$REPO/lib/nightfall-cmdline-check.sh}"
KCL="$REPO/lib/kernel-cmdline.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0

entry() {   # entry <i915 options> | entry none
    if [ "$1" = none ]; then rm -f "$T/c.cfg"; return; fi
    printf '### BEGIN nightfall-boot-manager ###\nmenuentry x --id nightfall {\n        linux   /boot/nightfall/vmlinuz %s\n}\n### END nightfall-boot-manager ###\n' "$1" > "$T/c.cfg"
}
expect() {  # expect <name> <exit> <command...>
    local name="$1" want="$2"; shift 2
    "$@" >/dev/null 2>&1; local got=$?
    if [ "$got" = "$want" ]; then pass=$((pass + 1))
    else fail=$((fail + 1)); echo "FAIL  $name  (want $want, got $got)"; fi
}
# The host's own NIGHTFALL_CMDLINE must not leak into a case that is not about it.
check()    { printf '%s\n' "$1" > "$T/cmdline"
             env -u NIGHTFALL_CMDLINE PICKER_CFG="$T/c.cfg" PROC_CMDLINE="$T/cmdline" "$CHECK"; }
override() { printf '%s\n' "$1" > "$T/cmdline"
             env NIGHTFALL_CMDLINE="$2" PICKER_CFG="$T/c.cfg" PROC_CMDLINE="$T/cmdline" "$CHECK"; }
drift()    { printf '%s\n' "$1" > "$T/cmdline"
             PICKER_CFG="$T/c.cfg" PROC_CMDLINE="$T/cmdline" "$KCL" picker-drift; }

PANEL='i915.enable_dpcd_backlight=2 i915.enable_psr=0'
RECOVERY='root=UUID=x ro recovery nomodeset dis_ucode_ldr'

# ---- nightfall-cmdline-check: may this boot rebuild Nightfall's entry? -------
entry "$PANEL"
expect "normal boot, same options"                      0 check "ro quiet splash $PANEL"
expect "normal boot, an option added and booted"        0 check "ro quiet $PANEL i915.x=1"
expect "normal boot after a revert, fewer options"      0 check "ro quiet i915.enable_psr=0"
expect "recovery boot, entry has options"               1 check "$RECOVERY"
expect "no i915 while the entry has some"               1 check "ro quiet splash"
expect "unreadable cmdline"                             1 env -u NIGHTFALL_CMDLINE PICKER_CFG="$T/c.cfg" PROC_CMDLINE="$T/missing" "$CHECK"
expect "recovery boot with explicit override"           0 override "$RECOVERY" "i915.enable_psr=0"

# Cases where the nomodeset/recovery WORD check is the only thing that refuses.
entry none
expect "ONLY-WORD: first install from a recovery boot"  1 check "$RECOVERY"
entry "$PANEL"
expect "ONLY-WORD: nomodeset boot still carrying i915"  1 check "ro quiet nomodeset $PANEL"
expect "ONLY-WORD: recovery boot still carrying i915"   1 check "ro recovery $PANEL"

# The case where the no-options rule is the only thing that refuses.
expect "ONLY-EMPTY: one-time edit dropped every i915"   1 check "ro quiet splash"

# Allowed on purpose.
entry ""
expect "panel that genuinely needs no i915 options"     0 check "ro quiet splash"
entry none
expect "first install from a normal boot"               0 check "ro quiet splash $PANEL"

# ---- picker-drift: flags only Nightfall's entry LACKING an option ------------
entry "$PANEL"
expect "drift: identical"                               1 drift "ro $PANEL"
expect "drift: entry has an extra option (after revert)" 1 drift "ro i915.enable_psr=0"
expect "drift: entry lacks one the kernel boots with"   0 drift "ro $PANEL i915.x=1"
entry "i915.enable_psr=1"
expect "drift: same key, different value"               0 drift "ro i915.enable_psr=0"
expect "drift: unreadable cmdline cannot tell"          2 env PICKER_CFG="$T/c.cfg" PROC_CMDLINE="$T/missing" "$KCL" picker-drift

# ---- boot-menu: what `show` says Nightfall will use -------------------------
# By value, as Nightfall's init reads it: padded digits of any length are the
# number they spell (confirmed by the Nightfall session under dash and busybox
# sh), and a padded non-default value showing as the default is a lie about
# what boots - worst for the timeout, where 0 means never auto-boot.
BM="$REPO/lib/boot-menu.sh"
bm_show() { NF_TIMEOUT_FILE="$T/nt" NF_SPLASH_MS_FILE="$T/nms" NF_ROTATE_FILE="$T/x" \
            NF_AUTOROTATE_FILE="$T/x" NF_SPLASH_FILE="$T/x" GRUB_FILE="$T/x" "$BM" show; }
shows() {   # shows <file> <written value> <pattern show must contain>
    # Captured first: `show | grep -q` under pipefail dies of SIGPIPE (141)
    # when grep matches early, and would also hide show's own exit status.
    printf '%s\n' "$2" > "$T/$1"
    local out; out=$(bm_show) || return 9
    grep -q -- "$3" <<< "$out"
}
expect "show exits 0 with ordinary settings"            0 bm_show
expect "timeout: padded value is its number"            0 shows nt 000000120 "Nightfall menu         120s"
expect "timeout: padded 0 still disables auto-boot"     0 shows nt 0000 "auto-boot DISABLED"
expect "timeout: padded over limit is ignored"          0 shows nt 003601 "Nightfall menu         30s"
expect "timeout: too big to compare is ignored"         0 shows nt 99999999999999999999 "Nightfall menu         30s"
expect "splash-ms: padded non-default is its number"    0 shows nms 000002500 "at least 2.5s each"
expect "splash-ms: long padding is fine"                0 shows nms 00000000000000000000001500 "at least 1.5s each"
expect "splash-ms: padded exactly the limit"            0 shows nms 010000 "at least 10s each"
expect "splash-ms: padded over the limit is ignored"    0 shows nms 010001 "at least 1.5s each"
expect "splash-ms: quarter second shown as 0.25"        0 shows nms 250 "at least 0.25s each"
expect "splash-ms: odd value shown exactly"             0 shows nms 1600 "at least 1.6s each"

# splash-secs writes milliseconds, exactly.
secs() {    # secs <input> <file content expected>
    rm -f "$T/nms"
    NF_SPLASH_MS_FILE="$T/nms" NF_SPLASH_FILE="$T/x" FIXER_SUDO=env "$BM" splash-secs "$1" || return 9
    [ "$(cat "$T/nms")" = "$2" ]
}
expect "splash-secs: 1.25 -> 1250"                      0 secs 1.25 1250
expect "splash-secs: .75 -> 750"                        0 secs .75 750
expect "splash-secs: 10 -> 10000"                       0 secs 10 10000
expect "splash-secs: 0 -> 0"                            0 secs 0 0
expect "splash-secs: 02.5 -> 2500"                      0 secs 02.5 2500
expect "splash-secs: 10.001 refused"                    9 secs 10.001 x
expect "splash-secs: 1.2345 refused"                    9 secs 1.2345 x
expect "splash-secs: -1 refused"                        9 secs -1 x
expect "splash-secs: 1. refused"                        9 secs 1. x
expect "splash-secs: abc refused"                       9 secs abc x

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
