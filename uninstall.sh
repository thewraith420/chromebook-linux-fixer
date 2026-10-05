#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Remove what install.sh created. Applied fixes are NOT reverted - use
# "nightfall-toolkit revert <id>" for those first if that is what you want.
set -euo pipefail

BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
ICONS="$HOME/.local/share/icons/hicolor/scalable/apps"

# The chromebook-fixer names are what install.sh used before 2026-10-05.
for prog in nightfall-toolkit nightfall-toolkit-gui chromebook-fixer chromebook-fixer-gui; do
    if [ -L "$BIN/$prog" ]; then
        rm -f "$BIN/$prog"
        echo "  removed $BIN/$prog"
    fi
done
for f in "$APPS/io.github.thewraith420.NightfallToolkit.desktop" \
         "$ICONS/io.github.thewraith420.NightfallToolkit.svg" \
         "$APPS/org.chromebookfixer.Gui.desktop" \
         "$ICONS/org.chromebookfixer.Gui.svg"; do
    if [ -e "$f" ]; then
        rm -f "$f"
        echo "  removed $f"
    fi
done
command -v gtk-update-icon-cache >/dev/null && \
    gtk-update-icon-cache -qtf "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

echo
echo "Note: any fixes you applied are still applied."
echo "Run 'bin/nightfall-toolkit status' from the repo to review them."
