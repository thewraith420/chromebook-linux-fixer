#!/bin/bash
# fixes/waydroid-lxc-hook/{detect,apply,verify,revert}.sh against fixture LXC
# config files. Nothing here touches a real Waydroid install.
#
# Two unrelated bugs share this one fix id, by design (Slate-Session's call,
# 2026-09-30): the post-stop hook that stops a container restarting, and
# Android inside the container apparently chmod/chowning the HOST's real
# /proc/cmdline (observed going from world-readable to 0440 the moment
# Waydroid starts - a procfs entry's mode is believed to live in a struct
# shared with the host's mount of the same file). The fix for the second one
# is containment, not detection: bind-mount a private, read-only copy over
# the container's own proc/cmdline so Android never touches the real file at
# all. What matters here is that both bugs are tracked independently (a
# config missing just the containment line must still read as "needed"), the
# containment survives a config lacking the hook fix and vice versa, the
# snapshot refreshes rather than going stale, and revert undoes both together.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECT="$REPO/fixes/waydroid-lxc-hook/detect.sh"
APPLY="$REPO/fixes/waydroid-lxc-hook/apply.sh"
VERIFY="$REPO/fixes/waydroid-lxc-hook/verify.sh"
REVERT="$REPO/fixes/waydroid-lxc-hook/revert.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0

expect() { local name="$1" want="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?
    if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL  $name  (want $want, got $got)"; fi; }
says()   { local name="$1" pat="$2"; shift 2; local out; out=$("$@" 2>&1)
    if grep -q -- "$pat" <<<"$out"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL  $name  (no '$pat' in: $(head -c 300 <<<"$out"))"; fi; }
lacks()  { local name="$1" pat="$2"; shift 2; local out; out=$("$@" 2>&1)
    if grep -q -- "$pat" <<<"$out"; then fail=$((fail+1)); echo "FAIL  $name  (unexpected '$pat')"; else pass=$((pass+1)); fi; }

CFG="$T/config_base"
PROC="$T/cmdline"
SNAP="$T/snapshot"

reset_fixture() {
    printf 'lxc.rootfs.path = /var/lib/waydroid\nlxc.hook.post-stop = /dev/null\n' > "$CFG"
    echo "BOOT_IMAGE=/vmlinuz root=/dev/sda2 ro quiet" > "$PROC"
    rm -f "$SNAP" "$CFG.chromebook-fixer.orig"
}

detect() { env WAYDROID_LXC_CONFIGS="$CFG" "$DETECT"; }
apply()  { env FIXER_SUDO=env WAYDROID_LXC_CONFIGS="$CFG" WAYDROID_CMDLINE_SNAPSHOT="$SNAP" \
               PROC_CMDLINE="$PROC" "$APPLY"; }
verify() { env WAYDROID_LXC_CONFIGS="$CFG" "$VERIFY"; }
revert() { env FIXER_SUDO=env WAYDROID_LXC_CONFIGS="$CFG" WAYDROID_CMDLINE_SNAPSHOT="$SNAP" "$REVERT"; }

# ---- the two bugs are tracked independently -------------------------------
reset_fixture
expect "fresh config: needed (both bugs present)"      0 detect
says   "  names the hook bug"                           "/dev/null" detect
says   "  names the containment gap too"                "does not contain" detect
expect "fresh config: not yet applied"                  1 verify

printf 'lxc.hook.post-stop = /bin/true\n' > "$CFG"   # hook already fine, containment missing
expect "hook already fine, containment missing: still needed" 0 detect
says   "  only names the containment gap"              "does not contain" detect
lacks  "  does not also claim the hook is broken"       "/dev/null" detect
expect "  not applied either (half fixed is not applied)" 1 verify

reset_fixture
echo "lxc.mount.entry = /x proc/cmdline none bind,ro 0 0" >> "$CFG"   # containment present, hook missing
expect "containment already present, hook missing: still needed" 0 detect
says   "  only names the hook bug"                      "/dev/null" detect
lacks  "  does not also claim containment is missing"   "does not contain" detect

# ---- apply fixes both, idempotently ---------------------------------------
reset_fixture
apply >/dev/null
expect "after apply: not needed"                        1 detect
expect "after apply: verify passes"                      0 verify
says   "  verify mentions both halves"                   "contained, in every" verify
holds_once() { [ "$(grep -c 'proc/cmdline' "$CFG")" = 1 ]; }
expect "exactly one mount.entry line, not stacked"       0 holds_once
BEFORE=$(cat "$CFG")
apply >/dev/null
AFTER=$(cat "$CFG")
expect "re-apply is a true no-op on the config"          0 bash -c "[ '$BEFORE' = '$AFTER' ]"

# ---- the snapshot is refreshed, not frozen at first install ---------------
echo "BOOT_IMAGE=/vmlinuz root=/dev/sda2 ro quiet SOMETHING_NEW=1" > "$PROC"
apply >/dev/null
says "a changed running cmdline is picked up on the next apply" "SOMETHING_NEW" cat "$SNAP"

# ---- an unreadable /proc/cmdline at apply time is handled, not fatal ------
reset_fixture
chmod 000 "$PROC"
if [ -r "$PROC" ]; then
    echo "SKIP: running as a user that ignores file permissions - cannot" \
         "exercise the unreadable-cmdline-at-apply-time case" >&2
else
    APPLY_OUT=$(apply 2>&1); APPLY_RC=$?
    expect "apply still succeeds with an unreadable /proc/cmdline"  0 bash -c "exit $APPLY_RC"
    says   "  and says it wrote a placeholder"                       "placeholder" echo "$APPLY_OUT"
    expect "  the fix still reads as applied (containment line is there)" 1 detect
    chmod 644 "$PROC"
    apply >/dev/null
    lacks "  a later apply with a readable cmdline replaces the placeholder" \
          "unavailable" cat "$SNAP"
fi
chmod 644 "$PROC" 2>/dev/null || true

# ---- revert undoes both halves and cleans up the snapshot -----------------
reset_fixture
apply >/dev/null
revert >/dev/null
expect "after revert: needed again"                     0 detect
says   "  the hook is back to broken"                    "/dev/null" bash -c "cat '$CFG'"
lacks  "  the mount.entry line is gone"                  "proc/cmdline" cat "$CFG"
expect "  the snapshot file is cleaned up"               1 bash -c "[ -e '$SNAP' ]"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
