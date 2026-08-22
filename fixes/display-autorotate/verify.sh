#!/bin/bash
set -uo pipefail
systemctl --user is-enabled chromebook-autorotate.service >/dev/null 2>&1 || exit 1
STATE=$(systemctl --user is-active chromebook-autorotate.service 2>/dev/null || true)
echo "rotation service enabled (currently $STATE)"
