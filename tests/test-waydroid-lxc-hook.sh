#!/bin/bash
# fixes/waydroid-lxc-hook/{detect,apply,verify,revert}.sh against fixture LXC
# config files. Nothing here touches a real Waydroid install.
#
# Two unrelated bugs share this one fix id, by design (Slate-Session's call,
# 2026-09-30): the post-stop hook that stops a container restarting, and
# Android inside the container apparently chmod/chowning the HOST's real
# /proc/cmdline (observed going from world-readable to 0440 the moment
# Waydroid starts). The fix for the second one is containment: bind-mount a
# private copy over the container's own proc/cmdline so Android never
# touches the real file at all.
#
# That bind MUST be read-write, not read-only - a real regression, proven on
# hardware 2026-10-01. c6f3110 shipped it with ",ro,"; Android's first-stage
# init does a fatal CHECKCALL chmod("/proc/cmdline", 0440) while booting, a
# read-only bind turns that into EROFS, and init aborts with SIGABRT, killing
# the container on every single boot. Dropping ",ro" fixed it on the Slate -
# Android's chmod+chown then lands on the snapshot file instead of the real
# one, which is the containment working as intended. What matters here, on
# top of everything the first version of this suite covered: a config still
# carrying the broken ",ro," form must read as NEEDED and NOT APPLIED (not
# "already fixed, just happens to be read-only" - that config's container is
# dead), apply migrates it to the correct form in place rather than stacking
# a second mount.entry line, the snapshot refresh survives Android having
# already chmod/chowned it to something unusual, and - item 5 of the
# regression report - apply costs exactly ONE privilege escalation, not the
# 6-8 separate ones the first version made pkexec prompt for on every apply.
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
holds()  { local name="$1"; shift; if [ "$@" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL  $name"; fi; }

CFG="$T/config_base"
PROC="$T/cmdline"
SNAP="$T/snapshot"
BROKEN_LINE="lxc.mount.entry = $SNAP proc/cmdline none bind,ro,optional,create=file 0 0"

reset_fixture() {
    printf 'lxc.rootfs.path = /var/lib/waydroid\nlxc.hook.post-stop = /dev/null\n' > "$CFG"
    echo "BOOT_IMAGE=/vmlinuz root=/dev/sda2 ro quiet" > "$PROC"
    rm -f "$SNAP" "$CFG.chromebook-fixer.orig"
}

# A $SUDO stub that logs one line per invocation rather than just running the
# command - so "apply costs one escalation" is checked by COUNTING, not by
# reading apply.sh's source and hoping it matches.
SUDO_LOG="$T/sudo.log"
SUDO_STUB="$T/sudo-stub"
cat > "$SUDO_STUB" <<EOF
#!/bin/bash
echo "call: \$*" >> "$SUDO_LOG"
exec "\$@"
EOF
chmod +x "$SUDO_STUB"

detect() { env WAYDROID_LXC_CONFIGS="$CFG" "$DETECT"; }
apply()  { : > "$SUDO_LOG"
           env FIXER_SUDO="$SUDO_STUB" WAYDROID_LXC_CONFIGS="$CFG" WAYDROID_CMDLINE_SNAPSHOT="$SNAP" \
               PROC_CMDLINE="$PROC" "$APPLY"; }
verify() { env WAYDROID_LXC_CONFIGS="$CFG" "$VERIFY"; }
revert() { env FIXER_SUDO="$SUDO_STUB" WAYDROID_LXC_CONFIGS="$CFG" WAYDROID_CMDLINE_SNAPSHOT="$SNAP" "$REVERT"; }

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
echo "lxc.mount.entry = /x proc/cmdline none bind 0 0" >> "$CFG"   # some (non-broken) mount present, hook missing
expect "containment already present, hook missing: still needed" 0 detect
says   "  only names the hook bug"                      "/dev/null" detect
lacks  "  does not also claim containment is missing"   "does not contain" detect

# ---- the read-only regression: a config carrying it must read as broken ---
reset_fixture
printf 'lxc.hook.post-stop = /bin/true\n%s\n' "$BROKEN_LINE" > "$CFG"
expect "broken read-only mount present: still needed"   0 detect
says   "  names it specifically, not as a generic gap"  "needs migrating" detect
lacks  "  does not claim containment is simply missing" "does not contain" detect
expect "  and does not read as applied"                 1 verify

# ---- apply fixes both, idempotently, and in ONE escalation ----------------
reset_fixture
apply >/dev/null
expect "after apply: not needed"                        1 detect
expect "after apply: verify passes"                      0 verify
says   "  verify mentions both halves"                   "contained read-write, in every" verify
lacks  "  the config does not carry ,ro,"                 ",ro," cat "$CFG"
holds_once() { [ "$(grep -c 'proc/cmdline' "$CFG")" = 1 ]; }
expect "exactly one mount.entry line, not stacked"       0 holds_once
expect "apply costs exactly one privilege escalation"    0 bash -c "[ \"\$(wc -l < '$SUDO_LOG')\" = 1 ]"
BEFORE=$(cat "$CFG")
apply >/dev/null
AFTER=$(cat "$CFG")
expect "re-apply is a true no-op on the config"          0 bash -c "[ '$BEFORE' = '$AFTER' ]"

# ---- migrating an existing broken install --------------------------------
reset_fixture
printf 'lxc.rootfs.path = /var/lib/waydroid\nlxc.hook.post-stop = /bin/true\n%s\n' "$BROKEN_LINE" > "$CFG"
apply >/dev/null
expect "migration: now not needed"                      1 detect
expect "migration: verify passes"                        0 verify
lacks  "  the broken form is gone, not just supplemented" ",ro," cat "$CFG"
expect "  exactly one mount.entry line, not two"          0 holds_once
says   "  the rest of the config survives untouched"      "lxc.rootfs.path" cat "$CFG"

# ---- the snapshot is refreshed, not frozen at first install ---------------
reset_fixture
apply >/dev/null
echo "BOOT_IMAGE=/vmlinuz root=/dev/sda2 ro quiet SOMETHING_NEW=1" > "$PROC"
apply >/dev/null
says "a changed running cmdline is picked up on the next apply" "SOMETHING_NEW" cat "$SNAP"

# ---- refresh survives Android having already chmod/chowned the snapshot --
# (item 4 of the regression report: cp into an EXISTING destination rewrites
# content only, leaving whatever mode is already there - exactly what lets
# this survive Android's own chmod/chown without a permission fight. In
# production $SUDO is real root/pkexec, which bypasses permission checks
# entirely (DAC_OVERRIDE), so it can rewrite the snapshot's content no matter
# what mode Android left it in, even 0440 owned by root. This fixture suite
# has no real root to prove THAT half with - FIXER_SUDO=env runs as the test
# user, who is genuinely blocked writing a 0440 file they own, same as any
# non-root process would be. What IS provable here, and is the actual
# mechanism in question: plain `cp` into a file that already exists does not
# reset its mode to the umask default - it only rewrites content. 0600 is
# used instead of 0440 so the test user's write still succeeds and the
# assertion is about cp's own behaviour, not about who is allowed to write.)
chmod 0600 "$SNAP"
echo "BOOT_IMAGE=/vmlinuz root=/dev/sda2 ro quiet AFTER_CHMOD=1" > "$PROC"
apply >/dev/null
says  "content still refreshes after the snapshot's mode changed" "AFTER_CHMOD" cat "$SNAP"
MODE=$(stat -c %a "$SNAP")
expect "and cp left that mode alone rather than resetting it"    0 bash -c "[ '$MODE' = '600' ]"
chmod 644 "$SNAP"

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

# revert from a migrated (previously-broken) install must also undo cleanly.
reset_fixture
printf 'lxc.hook.post-stop = /bin/true\n%s\n' "$BROKEN_LINE" > "$CFG"
MIGRATED_ORIG="$(cat "$CFG")"
apply >/dev/null       # migrates
revert >/dev/null
AFTER_REVERT="$(cat "$CFG")"
expect "revert after migration restores the pre-migration (still-broken) state" 0 \
    bash -c "[ '$MIGRATED_ORIG' = '$AFTER_REVERT' ]"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
