#!/bin/bash
set -uo pipefail
systemctl is-enabled chromebook-ec-buttons.service >/dev/null 2>&1 || exit 1
STATE=$(systemctl is-active chromebook-ec-buttons.service 2>/dev/null || true)
echo "EC button service enabled (currently $STATE)"
[ "$STATE" = active ] || exit 1
