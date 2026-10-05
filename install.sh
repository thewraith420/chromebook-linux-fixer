#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Put nightfall-toolkit on PATH and in the applications menu, for this user.
#
# Deliberately a per-user install with no root: the tool asks for privileges
# per fix, when a fix actually needs them, so there is no reason for the tool
# itself to be installed as root.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
ICONS="$HOME/.local/share/icons/hicolor/scalable/apps"
APP_ID="io.github.thewraith420.NightfallToolkit"

mkdir -p "$BIN" "$APPS" "$ICONS"

for prog in nightfall-toolkit nightfall-toolkit-gui; do
    ln -sfn "$REPO/bin/$prog" "$BIN/$prog"
    echo "  $BIN/$prog -> $REPO/bin/$prog"
done

install -m644 "$REPO/share/applications/$APP_ID.desktop" "$APPS/$APP_ID.desktop"
echo "  $APPS/$APP_ID.desktop"

# The desktop entry names its icon by app ID, so the file has to be in the
# icon theme under exactly that name or the launcher silently shows a blank
# tile - there is no error and no fallback once Icon= names something missing.
install -m644 "$REPO/share/icons/hicolor/scalable/apps/$APP_ID.svg" "$ICONS/$APP_ID.svg"
echo "  $ICONS/$APP_ID.svg"

# Before 2026-10-05 this was installed as chromebook-fixer. Those links now
# point at files that no longer exist, and the old menu entry would launch
# nothing, so remove them. `update toolkit` re-runs this script after a pull,
# which is how an older install cleans itself up. Only symlinks are removed:
# a real file of that name is not ours.
for old in chromebook-fixer chromebook-fixer-gui; do
    if [ -L "$BIN/$old" ]; then
        rm -f "$BIN/$old"
        echo "  removed the old $BIN/$old"
    fi
done
for old in "$APPS/org.chromebookfixer.Gui.desktop" "$ICONS/org.chromebookfixer.Gui.svg"; do
    if [ -e "$old" ]; then
        rm -f "$old"
        echo "  removed the old $old"
    fi
done

command -v update-desktop-database >/dev/null && \
    update-desktop-database "$APPS" 2>/dev/null || true
# Harmless when absent; GTK falls back to scanning the theme directory.
command -v gtk-update-icon-cache >/dev/null && \
    gtk-update-icon-cache -qtf "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

# The CLI needs nothing but Python's standard library and works right after
# the symlinks above. The GUI needs GTK4 and libadwaita's GObject-Introspection
# bindings, which several distros (Mint confirmed, 2026-09-20) do not install
# by default even when python3-gi itself is present - PyGObject only exposes
# the typelibs actually on disk, so `import gi` succeeds and the specific
# `from gi.repository import Gtk, Adw` fails, with no earlier warning. Checked
# here rather than left to be discovered as a bare traceback on first launch.
if ! python3 -c "
import gi
gi.require_version('Gtk', '4.0')
gi.require_version('Adw', '1')
from gi.repository import Gtk, Adw
" >/dev/null 2>&1; then
    echo
    echo "Note: the GUI (nightfall-toolkit-gui) needs GTK4 and libadwaita's"
    echo "GObject-Introspection bindings, and this system is missing at least"
    echo "one. The CLI above does not need them and works either way."
    if command -v apt-get >/dev/null; then
        echo "  sudo apt install python3-gi gir1.2-gtk-4.0 gir1.2-adw-1"
    else
        echo "  install your distro's packages for: python3-gi (PyGObject),"
        echo "  GTK4 and libadwaita GObject-Introspection typelibs"
    fi
fi

echo
case ":$PATH:" in
    *":$BIN:"*)
        echo "Installed. Start with:  nightfall-toolkit status" ;;
    *)
        # Common on a fresh Ubuntu: ~/.local/bin was not on PATH at login.
        # The stock ~/.profile adds it once the directory exists (which it now
        # does), so a future login self-heals - but this shell needs a nudge.
        echo "Installed to $BIN, which is not on this shell's PATH yet."
        echo "Your next login adds it automatically (the directory now exists)."
        echo "To use it in this shell right now:"
        echo
        echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo "    nightfall-toolkit status"
        echo
        echo "or just open a new terminal and run:  nightfall-toolkit status" ;;
esac
