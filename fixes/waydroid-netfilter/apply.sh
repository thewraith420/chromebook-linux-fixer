#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

# Escalation is chosen by the caller: plain sudo in a terminal, pkexec
# under the GUI, which has no tty to prompt on.
SUDO="${FIXER_SUDO:-sudo}"
SCRIPT=/usr/lib/waydroid/data/scripts/waydroid-net.sh
BACKUP="$SCRIPT.chromebook-fixer.orig"
[ -f "$BACKUP" ] || $SUDO cp -a "$SCRIPT" "$BACKUP"

$SUDO python3 - "$SCRIPT" <<'PY'
import re, sys

path = sys.argv[1]
src = open(path).read()

MARK = "chromebook-fixer"
if MARK in src:
    print("already patched; nothing to do")
    sys.exit(0)


def prefer_nft(text, base):
    """
    Swap waydroid's binary preference for one family.

    Upstream picks the -legacy binary first and falls back to the nft-backed
    one. On kernels built without CONFIG_NETFILTER_XTABLES_LEGACY the legacy
    binary exists but its ip_tables module cannot load, so the container fails
    to start. Reverse the order and keep -legacy as the fallback.

    Matched as a whole assignment block, deliberately. An earlier version
    replaced the first *textual* occurrence of "iptables-legacy", which on a
    file carrying a comment about iptables-legacy edited the comment and left
    the code alone.
    """
    var = base.upper() + "_BIN"
    pattern = re.compile(
        r'(?P<lead>^[ \t]*)' + var + r'="\$\(command -v ' + base + r'-legacy\)"[ \t]*\n'
        r'(?P<mid>[ \t]*if \[ ! -n "\$' + var + r'" \]; then[ \t]*\n)'
        r'(?P<ind>[ \t]*)' + var + r'="\$\(command -v ' + base + r'\)"',
        re.M)

    def swap(m):
        return (f'{m.group("lead")}{var}="$(command -v {base})"\n'
                f'{m.group("mid")}'
                f'{m.group("ind")}{var}="$(command -v {base}-legacy)"')

    return pattern.subn(swap, text, count=1)


src, n4 = prefer_nft(src, "iptables")
src, n6 = prefer_nft(src, "ip6tables")

if not (n4 or n6):
    print("preference order already favours the nft-backed binaries; leaving it alone")
    sys.exit(0)

# The marker MUST go after the shebang. Putting it on line 1 pushes "#!/bin/sh"
# to line 3, the kernel then finds no interpreter, and waydroid's subprocess
# call dies with ENOEXEC - which looks exactly like the failure this fix is
# meant to cure. That bug shipped once; hence the assertion below.
lines = src.split("\n")
at = 1 if lines and lines[0].startswith("#!") else 0
note = ["# Patched by chromebook-fixer: prefer the nft-backed iptables, because",
        "# kernels without CONFIG_NETFILTER_XTABLES_LEGACY cannot load ip_tables."]
lines[at:at] = note
src = "\n".join(lines)

assert src.split("\n")[0].startswith("#!"), "refusing to write: shebang is no longer first"

open(path, "w").write(src)
print(f"patched (iptables: {n4}, ip6tables: {n6})")
PY
echo "backup at $BACKUP"
