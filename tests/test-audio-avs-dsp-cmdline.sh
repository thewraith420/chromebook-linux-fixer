#!/bin/bash
# fixes/audio-avs-dsp/detect.sh's handling of an unreadable /proc/cmdline.
#
# The real bug this guards: /proc/cmdline can go unreadable while this
# machine is running (mode 0440, a leaked procfs permission change observed
# to track Waydroid's container running - see waydroid-lxc-hook). The old
# check was a bare `grep -qs ... /proc/cmdline && exit 1`: grep fails
# silently on an unreadable file, "&&" short-circuits to false, and detect
# falls straight through as though the parameter were simply absent - an
# already-applied cmdline fix would misreport as still needed the moment
# Waydroid had run since boot. It must report "cannot tell" (2) instead.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D="$REPO/fixes/audio-avs-dsp/detect.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0

expect() { local name="$1" want="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?
    if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL  $name  (want $want, got $got)"; fi; }
says()   { local name="$1" pat="$2"; shift 2; local out; out=$("$@" 2>&1)
    if grep -q -- "$pat" <<<"$out"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL  $name  (no '$pat' in: $(head -c 300 <<<"$out"))"; fi; }

# ---- get past the earlier gates: a real dsp_driver knob and a recognised
# AVS audio controller id, via a stub lspci on PATH. ------------------------
DSP_PARAM="$T/dsp_driver"; : > "$DSP_PARAM"
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/lspci" <<'EOF'
#!/bin/bash
echo "00:1f.3 0401: 8086:9d71 (rev 21)"
EOF
chmod +x "$BIN/lspci"
# No working analog output: pactl lists only HDMI, so the "safety: never
# touch a working setup" check does not itself stand this down before the
# cmdline check even runs.
cat > "$BIN/pactl" <<'EOF'
#!/bin/bash
echo "0	alsa_output.pci-0000_00_1f.3.hdmi-stereo	module-alsa-card.c	s16le 2ch 48000Hz	RUNNING"
EOF
chmod +x "$BIN/pactl"
MODD="$T/modprobe.d"; mkdir -p "$MODD"   # empty: not set this way

# run - PROC_CMDLINE comes from the CMDLINE variable, set by each case below
# (not passed inline: VAR=val only prefixes a literal command, not one
# reconstructed from "$@" inside expect/says).
run() {
    env PATH="$BIN:$PATH" DSP_DRIVER_PARAM="$DSP_PARAM" MODPROBE_D_DIR="$MODD" \
        XDG_RUNTIME_DIR="$T/xdgrt" PROC_CMDLINE="$CMDLINE" "$D"
}

# ---- readable cmdline: the ordinary, correct cases -----------------------
CMDLINE="$T/proc-cmdline"
echo "BOOT_IMAGE=/vmlinuz root=/dev/sda2 ro quiet" > "$CMDLINE"
says  "not already forced, no amp -> needed, says so" \
      "forcing the AVS driver should recover" run

echo "BOOT_IMAGE=/vmlinuz snd_intel_dspcfg.dsp_driver=4 ro quiet" > "$CMDLINE"
expect "already forced on a READABLE cmdline -> not needed (1)" 1 run

CMDLINE="$T/proc-cmdline"
echo "BOOT_IMAGE=/vmlinuz root=/dev/sda2 ro quiet" > "$CMDLINE"

# ---- the real bug: unreadable cmdline must never read as "absent" --------
NOPERM="$T/proc-cmdline-noperm"; echo "snd_intel_dspcfg.dsp_driver=4" > "$NOPERM"; chmod 000 "$NOPERM"
if [ -r "$NOPERM" ]; then
    echo "SKIP: running as a user that ignores file permissions (root?) -" \
         "cannot exercise the unreadable-file case" >&2
else
    CMDLINE="$NOPERM"
    expect "unreadable cmdline -> cannot tell (2), never silently 'absent'" 2 run
    says  "  says why, and does not guess"  "cannot read" run
fi
chmod 644 "$NOPERM" 2>/dev/null || true

CMDLINE="$T/does-not-exist"
expect "a /proc/cmdline that does not exist at all -> cannot tell (2)" 2 run

# ---- modprobe.d is checked FIRST and needs no cmdline read at all --------
echo "options snd_intel_dspcfg dsp_driver=4" > "$MODD/snd-avs.conf"
CMDLINE="$NOPERM"
expect "set via modprobe.d -> not needed (1), even with cmdline unreadable" 1 run
rm -f "$MODD/snd-avs.conf"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
