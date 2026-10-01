#!/bin/bash
set -uo pipefail
systemctl is-enabled chromebook-panel-brightness-aux.service >/dev/null 2>&1 || exit 1
STATE=$(systemctl is-active chromebook-panel-brightness-aux.service 2>/dev/null || true)
if [ "$STATE" = active ]; then
    echo "panel brightness bridge enabled (currently active)"
    exit 0
fi

# Not active is not necessarily broken, since apply.sh stopped refusing to
# install on a kernel that already drives DPCD (the install-time probe used
# to catch this; it was removable only because the daemon runs the same check
# itself, properly, at every startup - see apply.sh and dc5a29d). Type=simple
# plus Restart=on-failure means a clean "the kernel already drives this
# panel, standing down" (exit 0) and an actual crash both leave systemd
# reporting "inactive" a moment later - ask the daemon which one this is, via
# --why, the same question apply.sh asked before installing. Unprivileged
# here on purpose: verify runs on every background status sweep (the GUI's
# refresh), and $SUDO/pkexec would mean an authentication prompt on every one
# of those. --why without root falls back to the backlight-range heuristic
# (backlight_interface_hint in the daemon) instead of the authoritative AUX
# probe - less certain, but enough to tell "standing down on purpose" from
# "actually failed" without ever escalating from here.
# Same override apply.sh installs to, so a test can point both at one
# scratch file; default is the real installed path, unchanged.
DAEMON="${PANEL_AUX_BIN_DST:-/usr/local/bin/chromebook-panel-brightness-aux}"
if [ -x "$DAEMON" ]; then
    WHY=$("$DAEMON" --why 2>/dev/null || true)
    case "$WHY" in
        "stand down:"*)
            echo "kernel already drives this panel's DPCD backlight itself - $WHY"
            exit 3 ;;
    esac
fi

echo "panel brightness bridge enabled but not running (currently $STATE)"
exit 1
