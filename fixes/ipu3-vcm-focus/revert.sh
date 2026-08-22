#!/bin/bash
set -euo pipefail
sudo rm -f /etc/udev/rules.d/99-chromebook-vcm-focus.rules
sudo udevadm control --reload-rules
echo "removed the focus udev rule (lens returns to its power-on default)"
