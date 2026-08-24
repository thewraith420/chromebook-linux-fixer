#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Remove what install.sh created. Applied fixes are NOT reverted - use
# "chromebook-fixer revert <id>" for those first if that is what you want.
set -euo pipefail

BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"

for prog in chromebook-fixer chromebook-fixer-gui; do
    [ -L "$BIN/$prog" ] && rm -f "$BIN/$prog" && echo "  removed $BIN/$prog"
done
[ -e "$APPS/org.chromebookfixer.Gui.desktop" ] && \
    rm -f "$APPS/org.chromebookfixer.Gui.desktop" && \
    echo "  removed the desktop entry"

echo
echo "Note: any fixes you applied are still applied."
echo "Run 'chromebook-fixer status' from the repo to review them."
