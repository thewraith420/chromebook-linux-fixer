#!/bin/bash
# ec-buttons.sh — is the in-kernel Chrome EC button path actually delivering?
#
#   ec-buttons.sh goog0007    0 = cros-ec-keyb NOT bound (buttons dead)
#                             1 = bound and working
#                             2 = cannot tell
#
# There are two independent ways the volume buttons die on a Chrome EC
# convertible, and they need opposite responses:
#
#   1. The EC stops delivering MKBP events - its interrupt fires once at boot
#      and never again. Someone has to drain the event FIFO: kernel patch 9201,
#      or the ec-buttons-poll userspace service.
#
#   2. GOOG0007's ACPI _STA reports 0, so cros_ec_keyb never probes and no
#      volume-button input device is ever created. Seen on the Pixel Slate
#      after a MrChromebox coreboot update (2606.1; 2512.1 was fine).
#      Kernel patch 9207 forces the status back.
#
# These compose badly. Draining the FIFO does nothing if nothing is bound to
# turn those events into key presses - so a kernel that polls (case 1 fixed)
# with GOOG0007 still hidden (case 2 present) has working delivery and dead
# buttons.
#
# DO NOT rewrite this to read /sys/bus/acpi/devices/GOOG0007:00/status. That
# looks like the obvious check and is useless: status_show() in
# drivers/acpi/device_sysfs.c evaluates _STA against firmware directly and
# never consults acpi_device_override_status(), so it reports the same raw 0 on
# a kernel carrying patch 9207 as on one without it. Building detection on it
# means reporting "still broken" forever, including on a machine whose buttons
# demonstrably work.
#
# What the fix actually changes is whether the driver binds, so that is what
# this looks at. The driver's name is "cros-ec-keyb" with hyphens, while its
# module and source are cros_ec_keyb with underscores - the sysfs path uses the
# driver name.
set -uo pipefail

DRIVER=/sys/bus/platform/drivers/cros-ec-keyb

goog0007_status() {
    # Bound to its ACPI device: enumeration succeeded and the driver attached,
    # so volume keys reach userspace. True whether that took patch 9207 or the
    # firmware was reporting _STA correctly in the first place.
    for dev in "$DRIVER"/GOOG0007:*; do
        [ -e "$dev" ] && return 1
    done

    # Not bound. On a board that carries GOOG0007 this is the fault - either
    # firmware is hiding the device, or the driver is missing entirely. Callers
    # MUST have established that this board has one (a DMI gate) before
    # treating this as the answer: on hardware without GOOG0007 the symlink is
    # equally absent and means only "not applicable".
    [ -d "$DRIVER" ] && return 0

    # The driver is not registered at all - built as a module and not loaded,
    # or not built. On an affected board that is consistent with the fault
    # (nothing autoloads a driver for a device ACPI says is absent), but the
    # driver's absence alone is not proof. Ask ACPI enumeration instead.
    #
    # physical_node is the platform device the ACPI core creates for a node it
    # considers present. No node, no device for any driver to ever bind to.
    # This is NOT the /status trap documented above: status_show() re-evaluates
    # _STA against firmware and ignores the kernel's override, whereas
    # enumeration goes through acpi_bus_get_status(), which consults
    # acpi_device_override_status() - so patch 9207 makes physical_node appear
    # while /status still reads 0. Verified on the reference machine: hidden
    # GOOG0007:00 has no physical_node, while GOOG0004:00 (the EC, _STA = 15)
    # has physical_node and physical_node1.
    if [ -d /sys/bus/acpi/devices/GOOG0007:00 ]; then
        for node in /sys/bus/acpi/devices/GOOG0007:*/physical_node*; do
            [ -e "$node" ] && return 2   # enumerated, but no driver bound to it
        done
        return 0                          # not enumerated: firmware hides it
    fi

    # No GOOG0007 on this board at all - not applicable, not a fault.
    return 2
}

case "${1:-}" in
    goog0007) goog0007_status ;;
    *) echo "usage: $0 goog0007" >&2; exit 2 ;;
esac
