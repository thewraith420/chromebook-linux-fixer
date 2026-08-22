#!/bin/bash
# Resolve a media entity name to its /dev/v4l-subdevN.
#
# /dev/v4l-subdev* numbering is NOT stable across reboots - it has shifted
# twice on the reference machine and caused wrong-device reads both times.
# Always resolve by entity name.
#
#   find-subdev.sh ak7375   ->  /dev/v4l-subdev6
#
# Prints nothing and exits 0 if no such entity exists (i.e. not this hardware).
set -uo pipefail
NEEDLE="${1:?usage: find-subdev.sh <entity-name-substring>}"

command -v media-ctl >/dev/null 2>&1 || exit 2

for media in /dev/media*; do
    [ -e "$media" ] || continue
    media-ctl -d "$media" -p 2>/dev/null | awk -v needle="$NEEDLE" '
        /^- entity [0-9]+:/ {
            ent = $0
            sub(/^- entity [0-9]+: /, "", ent)
            sub(/ \(.*/, "", ent)
        }
        /device node name \/dev\/v4l-subdev/ {
            if (ent ~ needle) { print $NF; found=1; exit }
        }
        END { exit(found ? 0 : 1) }
    ' && exit 0
done
exit 0   # not found is not an error: the hardware simply is not present
