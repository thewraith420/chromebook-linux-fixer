#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Put chromebook-fixer on PATH and in the applications menu, for this user.
#
# Deliberately a per-user install with no root: the tool asks for privileges
# per fix, when a fix actually needs them, so there is no reason for the tool
# itself to be installed as root.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"

mkdir -p "$BIN" "$APPS"

for prog in chromebook-fixer chromebook-fixer-gui; do
    ln -sfn "$REPO/bin/$prog" "$BIN/$prog"
    echo "  $BIN/$prog -> $REPO/bin/$prog"
done

install -m644 "$REPO/share/applications/org.chromebookfixer.Gui.desktop" \
    "$APPS/org.chromebookfixer.Gui.desktop"
echo "  $APPS/org.chromebookfixer.Gui.desktop"

command -v update-desktop-database >/dev/null && \
    update-desktop-database "$APPS" 2>/dev/null || true

case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo
       echo "NOTE: $BIN is not on your PATH. Add it to your shell profile:"
       echo "      export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

echo
echo "Installed. Start with:  chromebook-fixer status"
