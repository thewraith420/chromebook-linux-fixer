# chromebook-linux-fixer

A CLI (+ GUI) that packages Chromebook Linux hardware-enablement fixes as self-contained, detection-gated units — camera (IPU3), display/rotation, audio, EC/buttons, fingerprint, Waydroid, zram. Built and tested on exactly one machine: the Google Pixel Slate (Nocturne). Every fix is hardware-detected, but detection is imperfect on other hardware, and the README is explicit about that.

**A bad interaction can hard-lock the machine with no panic and nothing logged** — this happened three times during IPU3 camera work. Treat every `apply` as genuinely risky, not routine.

## This is one of three related but separate Slate projects
- **This repo** — userspace hardware-fix tool, runs on the daily-driver OS.
- **[BobZKernel](https://github.com/thewraith420/BobZKernel)**, `pixel-slate` branch — the actual installed kernel + patches. `picker-kernel` branch — a stripped-down kernel for the touch boot picker below.
- **[nocturne-boot-picker](https://github.com/thewraith420/nocturne-boot-picker)** — TWRP-style touch `kexec` boot picker, working end-to-end as of 2026-09-01.

They overlap more than they look like they should — see "Non-obvious overlaps" below before assuming something here is unrelated to those repos.

## Design pattern per fix
`fixes/<id>/fix.yaml` (metadata/risk/category/description) + up to four scripts:
- `detect.sh` — 0 = problem present, 1 = not needed, 2 = can't tell
- `verify.sh` — 0 = our fix is in place and working, **3 = desired state holds but something ELSE achieved it** (not "our fix"). This exists because of a real incident: the IPU3 IOMMU fix's `verify` saw a safe `identity` domain on a stock kernel — mainline's own VT-d quirk did it, no bootloader parameter was ever added — and would have wrongly reported "applied." Keeping `detect`/`verify` conceptually separate ("problem exists" vs "our fix is installed") is deliberate, not incidental.
- `apply.sh` / `revert.sh`
- Convention: `SUDO="${FIXER_SUDO:-sudo}"`, never bare `sudo`.

## Collaboration pattern
Commits alternate between "bob" (Slate-side Claude session, hands-on hardware testing) and "thewraith420" (this machine's session lineage). **Real collision history — `git pull --rebase` before committing, always, and check existing fixes first**: `waydroid-netfilter` was independently rewritten by both sides (`63aeadf`, "fix a patch that broke the thing it was fixing"), and a duplicate audio fix got added twice (`434f56e`).

## Live status as of 2026-09-01 (ground truth — `chromebook-fixer status` run on the actual Slate)
19 fixes.
- **Needed, not yet applied**: `camera-follow-rotation` — camera image doesn't follow screen rotation (prefers `display-autorotate`, already applied). Works via `libcamerasrc -> videoflip -> v4l2loopback`, rotation applied live from the accelerometer. **The real current to-do.**
- **Unknown/can't-tell**: `ipu3-imgu-grableak` — real documented bug (`imgu_vb2_start_streaming()` returns 0 even on `imgu_s_stream()` failure; `pipe_mode` control stays grabbed until reboot), fixed via a DKMS-rebuilt ipu3-imgu module. `detect.sh` currently can't determine state — worth checking if it resurfaces.
- **Applied**: `camera-orientation`, `ipu3-vcm-focus`, `ipu3-camera`, `display-autorotate`, `panel-brightness-dpcd`, `cros-fp-fingerprint`, `waydroid-lxc-hook`, `waydroid-usb`, `zram-swap`.
- **Not needed on this kernel/board**: `ipu3-imgu-iommu`, `accelerometer-orientation`, `backlight-permissions`, `tablet-mode-switch`, `audio-avs-dsp`, `ec-buttons-dkms`, `ec-buttons-poll`, `waydroid-netfilter`.

## Non-obvious overlaps with BobZKernel / nocturne-boot-picker

1. **Volume buttons — two different bugs, currently both resolved, don't conflate them.** `ec-buttons-poll`/`ec-buttons-dkms` exist because "the EC never delivers MKBP events after boot — the interrupt fires once at startup and never again" (polls the EC FIFO via the synchronous command path instead). This is a **different failure mode** from BobZKernel's patch 9207 (GOOG0007's ACPI `_STA` misreporting absent after a coreboot firmware update, fixed via `override_status_ids[]` so `cros_ec_keyb` binds at all). Both currently report "not needed" — but if volume buttons go silent again specifically **after long uptime** (not right after boot), that's the interrupt-starvation problem these fixes describe, not the ACPI one.
2. Kernel patch **9201** (`cros-ec-poll-event-fifo-fallback.patch`, BobZKernel `pixel-slate` branch) is the in-tree version of the same idea as `ec-buttons-dkms` — deliberately not offered here as a fixer fix, since this tool avoids requiring kernel rebuilds.
3. **`panel-brightness-dpcd` is the same fix as nocturne-boot-picker's blank-screen bug**, independently found from two directions. This fixer sets `i915.enable_dpcd_backlight=2` on the main kernel because "i915 picks a backlight control method the panel does not implement." The picker's bare GRUB entry (no cmdline at all) hit the identical root fact — DRM mode-set succeeds, screen stays dark — fixed in `install-picker.sh` by copying `i915.*` params live from `/proc/cmdline` (a more general version of what this fixer does explicitly).
4. `ipu3-imgu-iommu` / kernel patch 9204 is the same IOMMU identity-domain requirement (PCI `8086:1919`) as documented for pixel-slate camera work — cross-referenced, not duplicated.
5. `accelerometer-orientation`/`display-autorotate`/`tablet-mode-switch` are **existing working prior art** for nocturne-boot-picker's deferred auto-rotate idea. `display-autorotate` is applied and working on the full OS via `cros_ec_sensorhub`/`cros_ec_accel` — so that driver chain does work on the full BobZKernel build. The open question for picker auto-rotate narrows from "does this work at all" (yes) to "is that driver chain built into the stripped `picker-kernel` config specifically." Read this fix's `detect.sh`/`apply.sh` before starting picker auto-rotate work.

## Local paths
- This checkout: `~/buildstuff/chromebook-linux-fixer` (kept in sync with GitHub, this is the canonical working copy)
- Installed CLI: `~/.local/bin/chromebook-fixer` (+ `chromebook-fixer-gui`)
- On the Slate: `~/chromebook-fixer`
