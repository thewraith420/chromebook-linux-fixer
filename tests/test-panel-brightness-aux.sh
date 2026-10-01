#!/bin/bash
# fixes/panel-brightness-aux/{apply,verify,detect}.sh's firmware/kernel-aware
# standdown, against a stub daemon, systemctl and install. Nothing here
# touches the real system - $SUDO=env, every sysfs/service/binary path is a
# scratch fixture, and `install`/`systemctl` are stubs on PATH that never
# write to /usr/local/bin or /etc/systemd/system for real.
#
# What this guards: apply.sh used to REFUSE to install on a kernel its own
# one-shot probe thought was already driving DPCD - a probe dc5a29d found
# could be fooled by a desktop's automatic brightness, wrongly blocking
# install on a dual-boot machine that genuinely needs this on some of its
# kernels. It now always installs and defers to the daemon's own startup
# check instead - but Type=simple + Restart=on-failure makes a clean
# "stand down, exit 0" look exactly like a crash to systemd, so apply.sh's
# own "did it start" check and verify.sh both have to ask the daemon WHY it
# is inactive, not just whether it is, or a correct standdown would report
# as a broken install forever after.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="$REPO/fixes/panel-brightness-aux/apply.sh"
V="$REPO/fixes/panel-brightness-aux/verify.sh"
D="$REPO/fixes/panel-brightness-aux/detect.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0

expect() { local name="$1" want="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?
    if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL  $name  (want $want, got $got)"; fi; }
says()   { local name="$1" pat="$2"; shift 2; local out; out=$("$@" 2>&1)
    if grep -q -- "$pat" <<<"$out"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL  $name  (no '$pat' in: $(head -c 400 <<<"$out"))"; fi; }
lacks()  { local name="$1" pat="$2"; shift 2; local out; out=$("$@" 2>&1)
    if grep -q -- "$pat" <<<"$out"; then fail=$((fail+1)); echo "FAIL  $name  (unexpected '$pat')"; else pass=$((pass+1)); fi; }

# ---- a scratch FIXER_REPO: just the daemon apply.sh needs to find ---------
FR="$T/fixerrepo"; mkdir -p "$FR/daemon"
WHY_FILE="$T/why-output"
cat > "$FR/daemon/chromebook-panel-brightness-aux" <<'EOF'
#!/bin/bash
[ "${1:-}" = --why ] && cat "$WHY_FILE"
exit 0
EOF
chmod +x "$FR/daemon/chromebook-panel-brightness-aux"
: > "$FR/daemon/chromebook-panel-brightness-aux.service"

# ---- a fake eDP AUX device and sysfs backlight - just discoverable names,
# never opened for real: apply.sh no longer opens the AUX chardev itself,
# that is entirely the daemon's job now. ------------------------------------
AUXD="$T/sys-aux"; mkdir -p "$AUXD"; : > "$AUXD/drm_dp_aux0-eDP-1"
BLD="$T/sys-bl"; mkdir -p "$BLD/panel"; : > "$BLD/panel/brightness"
echo 7500 > "$BLD/panel/max_brightness"   # the native-PWM range: the fault this fixes
DMI_V="$T/dmi-vendor"; DMI_P="$T/dmi-product"
echo Google > "$DMI_V"; echo Nocturne > "$DMI_P"   # the one confirmed board

# ---- stub PATH: `install` and `systemctl` never touch the real system -----
BIN="$T/bin"; mkdir -p "$BIN"
INSTALL_LOG="$T/install.log"; SYSTEMCTL_LOG="$T/systemctl.log"
cat > "$BIN/install" <<EOF
#!/bin/bash
echo "install \$*" >> "$INSTALL_LOG"
EOF
cat > "$BIN/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$SYSTEMCTL_LOG"
case "\$1" in
    is-active)
        if [ "\${FAKE_ACTIVE:-0}" = 1 ]; then echo active; exit 0
        else echo inactive; exit 3; fi ;;
    is-enabled) [ "\${FAKE_ENABLED:-1}" = 1 ] && exit 0 || exit 1 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$BIN/install" "$BIN/systemctl"

BIN_DST="$T/installed-daemon"    # apply.sh's install target AND verify.sh's lookup

run_apply() {
    env PATH="$BIN:$PATH" FIXER_SUDO=env FIXER_REPO="$FR" WHY_FILE="$WHY_FILE" \
        DRM_DP_AUX_DIR="$AUXD" BACKLIGHT_DIR="$BLD" PANEL_AUX_BIN_DST="$BIN_DST" \
        PANEL_AUX_UNIT_DST="$T/installed.service" \
        FAKE_ACTIVE="${FAKE_ACTIVE:-0}" "$A"
}
run_verify() {
    env PATH="$BIN:$PATH" PANEL_AUX_BIN_DST="$BIN_DST" WHY_FILE="$WHY_FILE" \
        FAKE_ACTIVE="${FAKE_ACTIVE:-0}" FAKE_ENABLED="${FAKE_ENABLED:-1}" "$V"
}
run_detect() {
    env PATH="$BIN:$PATH" DRM_DP_AUX_DIR="$AUXD" BACKLIGHT_DIR="$BLD" \
        DMI_SYS_VENDOR="$DMI_V" DMI_PRODUCT_NAME="$DMI_P" "$D"
}

# ===== apply.sh: no longer refuses, regardless of what the daemon reports ==
printf 'run: kernel leaves DPCD alone (sysfs moved, register did not follow)\n' > "$WHY_FILE"
FAKE_ACTIVE=1
expect "apply: kernel not driving DPCD -> installs and runs"  0 run_apply
says   "  the service is actually installed (daemon copied)"  "install " cat "$INSTALL_LOG"
says   "  reports running, not idle"                           "running" run_apply

printf 'stand down: kernel drives DPCD itself (register tracked sysfs during the probe)\n' > "$WHY_FILE"
FAKE_ACTIVE=0
expect "apply: kernel ALREADY driving DPCD -> still installs (the fix)" 0 run_apply
says   "  the service is still installed, not skipped"         "install " cat "$INSTALL_LOG"
says   "  says it is installing anyway"                        "Installing anyway" run_apply
says   "  and reports idle-as-expected, not a failure"          "idle on this kernel as expected" run_apply
lacks  "  never claims the service is running when it is not"   "Brightness bridge running" run_apply
lacks  "  and never prints the scary failure banner"            "service failed to start" run_apply

# the daemon could not tell (cannot-tell / probe error): still installs,
# and since systemctl reports inactive with no "stand down" reason, THAT
# is correctly treated as a real failure, not silently swallowed.
printf 'run: probe error: [Errno 5] some I/O error\n' > "$WHY_FILE"
FAKE_ACTIVE=0
expect "apply: daemon errored (not a stand-down) + inactive -> real failure" 1 run_apply
says   "  still reports the failure banner"                     "service failed to start" run_apply

# ===== verify.sh: active always wins; inactive needs a reason =============
FAKE_ENABLED=1 FAKE_ACTIVE=1
expect "verify: enabled and active -> applied (0)"              0 run_verify
says   "  says active"                                          "currently active" run_verify

FAKE_ENABLED=0 FAKE_ACTIVE=0
expect "verify: not enabled at all -> not applied (1)"          1 run_verify

cp "$FR/daemon/chromebook-panel-brightness-aux" "$BIN_DST"; chmod +x "$BIN_DST"
printf 'stand down: kernel drives DPCD itself (register tracked sysfs during the probe)\n' > "$WHY_FILE"
FAKE_ENABLED=1 FAKE_ACTIVE=0
expect "verify: enabled, inactive, daemon says stand-down -> ok (3)" 3 run_verify
says   "  explains why, not just that"                           "kernel already drives" run_verify

printf 'run: cannot read DPCD ([Errno 5] input/output error); assuming the kernel does not\n' > "$WHY_FILE"
FAKE_ENABLED=1 FAKE_ACTIVE=0
expect "verify: enabled, inactive, daemon says run (genuine failure) -> broken (1)" 1 run_verify
lacks  "  does not misreport a crash as 'nothing to do'"          "nothing for this fix" run_verify

rm -f "$BIN_DST"
FAKE_ENABLED=1 FAKE_ACTIVE=0
expect "verify: daemon binary missing entirely -> falls back to broken (1)" 1 run_verify

# ===== detect.sh: unaffected by this change, still finds the device =======
expect "detect: eDP AUX + backlight present, nothing installed -> needed" 0 run_detect
rm -rf "$AUXD"/*
expect "detect: no eDP AUX device -> not applicable"            1 run_detect

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
