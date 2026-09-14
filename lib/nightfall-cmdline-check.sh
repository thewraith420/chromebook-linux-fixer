#!/bin/bash
# nightfall-cmdline-check.sh — is THIS boot a safe source for Nightfall's
# panel settings?
#
#   exit 0 = safe to (re)install Nightfall from this boot
#   exit 1 = refuse; the reason is printed
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

if [ -z "$running" ] && [ -n "$existing" ]; then
    echo "This boot carries no i915 options, but Nightfall's entry has: $existing"
    echo "Installing would drop them. That usually means a one-time edited command"
    echo "line rather than a real change - reboot normally and apply from there, or"
    echo "set NIGHTFALL_CMDLINE if the entry really should carry none."
    exit 1
fi

echo "Nightfall's entry will carry this boot's i915 options: ${running:-(none)}"
exit 0
