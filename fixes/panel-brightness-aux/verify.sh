#!/bin/bash
set -uo pipefail
systemctl is-enabled chromebook-panel-brightness-aux.service >/dev/null 2>&1 || exit 1
STATE=$(systemctl is-active chromebook-panel-brightness-aux.service 2>/dev/null || true)
echo "panel brightness bridge enabled (currently $STATE)"
[ "$STATE" = active ] || exit 1
