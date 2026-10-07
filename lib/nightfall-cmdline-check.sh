#!/bin/bash
# nightfall-cmdline-check.sh — is THIS boot a safe source for Nightfall's
# panel settings?
#
#   exit 0 = safe to (re)install Nightfall from this boot
#   exit 1 = refuse; the reason is printed
#   exit 3 = refuse, but only because this boot lacks i915 options Nightfall's
#            entry carries. The line "NF_I915_ENTRY=<options>" is printed too,
#            so the GUI can offer to keep them (NIGHTFALL_CMDLINE=<options>) or
#            drop them (NIGHTFALL_CMDLINE=) rather than just failing.
#
# install-nightfall.sh does not edit its boot entry. It deletes the whole
# marked block and writes a fresh one whose i915 options come from
# /proc/cmdline - the running kernel's - unless NIGHTFALL_CMDLINE is set. That
# is a sound rule on a normal boot: a system that booted and is showing you its
# desktop has just proved that i915 set lights the panel. It is also why the
# fixer does not try to preserve i915 options Nightfall's entry kept across a
# revert: a reinstall from a normal boot is exactly the right moment for them
# to be dropped.
#
# The proof does not hold on every boot, though, and the installer does not
# check. A recovery boot is "ro recovery nomodeset": nomodeset turns kernel
# modesetting off, so the panel lights through a different path and the running
# command line carries no i915 options at all. Reinstalling from there writes an
# EMPTY i915 set into Nightfall's entry - and on this panel that is a Nightfall
# that comes up dark. A one-time Edit that dropped the i915 options produces the
# same thing. Both are refused here, before a build that takes minutes.
set -uo pipefail

PROC="${PROC_CMDLINE:-/proc/cmdline}"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

i915_set() { tr ' ' '\n' | grep '^i915\.' | sort | tr '\n' ' ' | sed 's/ *$//'; }

if [ -n "${NIGHTFALL_CMDLINE+x}" ]; then
    # Explicit beats inferred: the person has said what the entry should carry.
    echo "Nightfall's entry will carry NIGHTFALL_CMDLINE as given: '${NIGHTFALL_CMDLINE}'"
    exit 0
fi

if [ ! -r "$PROC" ]; then
    echo "Cannot read $PROC, so Nightfall's panel settings cannot be taken from"
    echo "this boot - the installer would write an empty set into its entry."
    echo "Set them explicitly to install anyway, for example:"
    echo "  NIGHTFALL_CMDLINE='i915.enable_dpcd_backlight=2 i915.enable_psr=0'"
    exit 1
fi

cmdline=" $(cat "$PROC") "
running=$(i915_set < "$PROC")
existing=$("$LIB/kernel-cmdline.sh" picker-cmdline 2>/dev/null | i915_set)

case "$cmdline" in
    *" nomodeset "*|*" recovery "*)
        echo "This is a recovery or nomodeset boot, which is not a working display"
        echo "configuration for Nightfall: modesetting is off here, so the panel lights"
        echo "without any i915 options, and installing now would give Nightfall's entry"
        echo "none${existing:+ - it currently carries: $existing}."
        echo "Reboot into a normal entry and apply from there, or set NIGHTFALL_CMDLINE."
        exit 1 ;;
esac

# The saved per-kernel command line for the running kernel, from Nightfall's
# own nightfall-cmdline: keyed by the /vmlinuz-<release> suffix, last line
# wins, empty values ignored. Must match install-nightfall.sh's
# saved_override_for_running() and same_cmdline() exactly (nightfall-boot-manager
# 46d3fd3), or the two refuse different boots.
saved_override_for_running() {
    local file="${NF_CMDLINE_FILE:-${FIXER_BOOT_DIR:-/boot}/nightfall-cmdline}"
    local rel="${FIXER_RUNNING_KERNEL:-$(uname -r 2>/dev/null || true)}"
    [ -n "$rel" ] && [ -f "$file" ] || return 0
    awk -F'\t' -v suffix="/vmlinuz-$rel" '
        $2 != "" {
            k = $1
            if (length(k) >= length(suffix) && substr(k, length(k) - length(suffix) + 1) == suffix)
                v = $2
        }
        END { if (v != "") print v }' "$file"
}
same_cmdline() {
    norm() { printf '%s\n' "$1" | sed 's/BOOT_IMAGE=[^ ]* //; s/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'; }
    [ "$(norm "$1")" = "$(norm "$2")" ]
}

if [ -z "$running" ] && [ -n "$existing" ]; then
    # A bare boot that IS this kernel's saved override is a deliberate,
    # persistent choice (Bob's Slate boots 7.2.8 bare this way), not a one-off
    # edit - carry it forward rather than refuse it on every update.
    saved=$(saved_override_for_running)
    if [ -n "$saved" ] && same_cmdline "$(cat "$PROC")" "$saved"; then
        echo "This boot's command line is this kernel's saved override in nightfall-cmdline:"
        echo "a deliberate choice, not a one-off edit, so Nightfall's entry will carry no"
        echo "i915 options (it currently has: $existing)."
        exit 0
    fi
    echo "This boot carries no i915 options, but Nightfall's entry has: $existing"
    echo "This boot's command line is not this kernel's saved override either, so"
    echo "nothing says a bare command line is what Nightfall should carry, and"
    echo "dropping them could leave Nightfall dark. Choose explicitly: keep them or"
    echo "drop them (NIGHTFALL_CMDLINE, or the GUI's Keep/Drop choice)."
    echo "NF_I915_ENTRY=$existing"
    exit 3
fi

echo "Nightfall's entry will carry this boot's i915 options: ${running:-(none)}"
exit 0
