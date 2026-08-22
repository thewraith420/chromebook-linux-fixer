#!/bin/bash
set -euo pipefail
UNIT_DIR="$HOME/.config/systemd/user"
DAEMON="$FIXER_REPO/daemon/chromebook-autorotate"
[ -x "$DAEMON" ] || { echo "missing $DAEMON"; exit 1; }

# Warn about anything else already doing this, rather than silently fighting it.
CONFLICTS=$(grep -l "ClaimAccelerometer" \
    "$HOME/.local/share/gnome-shell/extensions"/*/extension.js 2>/dev/null \
    | sed 's|.*/extensions/||;s|/extension.js||' || true)
if [ -n "$CONFLICTS" ]; then
    echo "NOTE: these GNOME extensions also claim the accelerometer:"
    printf '  %s\n' $CONFLICTS
    echo "  Disable their rotation, or both will drive the display."
    echo
fi

mkdir -p "$UNIT_DIR"
sed "s|^ExecStart=.*|ExecStart=$DAEMON|" \
    "$FIXER_REPO/daemon/chromebook-autorotate.service" > "$UNIT_DIR/chromebook-autorotate.service"

systemctl --user daemon-reload
systemctl --user enable --now chromebook-autorotate.service
sleep 2
systemctl --user is-active chromebook-autorotate.service >/dev/null 2>&1 \
    && echo "rotation service running" \
    || { echo "service failed to start:"; systemctl --user status \
         chromebook-autorotate.service --no-pager -n 10; exit 1; }
