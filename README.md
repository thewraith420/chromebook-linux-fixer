# nightfall-toolkit

Install, update and manage [Nightfall Boot
Manager](https://github.com/thewraith420/nightfall-boot-manager) from the
desktop, plus hardware fixes for running Linux on a Google Pixel Slate.

**Nightfall** is a touch boot manager. It starts before your Linux system,
boots your kernels with `kexec`, lets you edit their command lines, installs
and removes kernels, and carries a repair menu. It runs on any x86-64 PC with
GRUB, driven by touch, keyboard or mouse. This toolkit installs it, keeps it up
to date, and handles the everyday management that would otherwise mean
rebooting into it: kernels, boot settings, per-kernel command lines and
backups.

**The hardware fixes** make a Pixel Slate (Nocturne) work properly under
Linux: the IPU3 cameras, screen rotation and brightness, the fingerprint reader
in the power button, audio, the volume buttons, and Waydroid. Each fix checks
whether this machine actually has the problem before it changes anything.

> Renamed from `chromebook-linux-fixer` (command `chromebook-fixer`) on
> 2026-10-05. An existing install switches to the new names the next time it
> updates itself (`chromebook-fixer update fixer`, on the old version). GitHub
> forwards the old repository address, so that update still finds it.

---

## ⚠ Read this before using it

**This tool makes low-level changes to your system.** Depending on what you
apply, that can mean adding a boot entry, replacing system libraries, editing
udev rules or PAM configuration, or changing kernel behaviour.

**Nightfall** is offered on any PC with GRUB and a CPU that meets
**x86-64-v2** (roughly 2009 or newer). Installing it refuses on an older CPU
before changing anything, because its kernel would not start there. It adds
its own GRUB entry and leaves your existing entries as they are. It has been
run end to end on two machines, a Pixel Slate and a Lenovo LOQ, so treat
anything else as untested.

**The hardware fixes** are developed and tested on exactly one machine, the
Pixel Slate. Every fix checks for its hardware first, but detection is
imperfect, and other machines differ in ways nobody here has seen.

Some of those fixes touch hardware that Linux supports poorly. **A bad
interaction can hard-lock the machine**, needing a forced power-off that can
corrupt a filesystem or lose unsaved work. That is not hypothetical: the IPU3
camera work behind this tool locked the Pixel Slate solid three times, with no
kernel panic and nothing written to any log.

**There is no warranty.** You are responsible for your own machine.

Sensible precautions:

- Read what a fix does first: `nightfall-toolkit list -v`
- Save your work before applying anything marked **HIGH RISK**
- Apply one fix at a time rather than `--all`
- Check `reverts_cleanly`: a few fixes cannot be cleanly undone

You are asked to acknowledge this once, before your first `apply`.

---

## Installing

```
git clone https://github.com/thewraith420/nightfall-toolkit.git
cd nightfall-toolkit
./install.sh          # per-user: links into ~/.local/bin and adds a menu entry
nightfall-toolkit status
```

If `~/.local/bin` is not on your `PATH` yet (common on a fresh Ubuntu),
`install.sh` says so. Open a new terminal, or run
`export PATH="$HOME/.local/bin:$PATH"`, then run the command again.

Installing needs no root. The tool asks for privileges only when a step needs
them, and batches each fix's root work into a single prompt. You can also run
it straight from the clone without installing.

`./uninstall.sh` removes the links and the menu entry. It does **not** undo
applied fixes; use `nightfall-toolkit revert <id>` for those.

The app is in your menu as **Nightfall Toolkit**. It
opens on Nightfall, with the hardware fixes one level down.

---

## Nightfall

Install it, and optionally make it the default GRUB entry:

```
nightfall-toolkit apply nightfall
nightfall-toolkit apply nightfall-default
```

Installing builds Nightfall's touch UI and boot image on this machine, because
they bundle this machine's own tools and libraries. It downloads the newest
Nightfall kernel from BobZKernel's releases and checks it against the
published `SHA256SUMS`. Missing build tools are installed with apt.

### Settings

```
nightfall-toolkit boot-menu                                # every boot setting, current values
nightfall-toolkit boot-menu --nightfall 20                 # Nightfall's menu timeout, seconds
nightfall-toolkit boot-menu --grub 5                       # GRUB's own menu timeout
nightfall-toolkit boot-menu --rotate 90 --autorotate off   # starting rotation; follow the accelerometer or not
nightfall-toolkit boot-menu --splash off --splash-secs 0.5 # boot screens on/off, minimum time each stays up
```

### Kernels

```
nightfall-toolkit kernels                                  # installed kernels, and Nightfall's default
nightfall-toolkit kernels --install <tarball> [--set-default]  # install a BobZKernel portable-installer tarball
nightfall-toolkit kernels --default <release>              # make Nightfall boot this one first
nightfall-toolkit kernels --remove <release>               # asks you to type the release first
nightfall-toolkit kernels --cmdline <release>              # the saved command line, or GRUB's own if none
nightfall-toolkit kernels --cmdline <release> --set "..."  # save a command line for this kernel
nightfall-toolkit kernels --cmdline <release> --reset      # drop it; fall back to GRUB's entry
```

`kernels` also lists leftovers: module folders with no kernel, packages apt
removed but never purged, and saved command lines for kernels that are gone.
Each can be removed like a kernel. Removal refuses the running kernel and the
last remaining one.

Saved command lines are the same `/boot/nightfall-cmdline` file Nightfall's
own Edit screen writes. They affect boots through Nightfall only; GRUB's own
entries stay as they are. Saving refuses a line that is empty, has no `root=`,
or contains a tab. In the GUI, each kernel's **Cmdline…** button opens the
same editor.

### Backups

```
nightfall-toolkit backups                                  # Nightfall's backups, on any mounted drive
nightfall-toolkit backups --delete <name>                  # asks you to type the name first
```

Nightfall takes backups on the Pixel Slate only for now, so the GUI shows this
section there, or on any machine where backups already exist.

Taking and restoring a backup stay in Nightfall, which does them with the real
system mounted read-only. Doing either from the running system would copy it
mid-write or overwrite it while in use. This toolkit only lists and deletes,
including incomplete backups Nightfall's own list hides, which are often the
biggest thing on the drive.

### Updates

```
nightfall-toolkit update                  # is anything behind? changes nothing
nightfall-toolkit update toolkit          # update this toolkit
nightfall-toolkit update nightfall        # newest Nightfall source and kernel, rebuilt and reinstalled
```

- **Nothing is merged or overwritten.** Both git checkouts update
  fast-forward only. A checkout with local changes or unpushed commits is
  refused, with the reason.
- **"Behind" means behind what is installed.** Nightfall counts as behind when
  the installed build came from an older commit than the Nightfall checkout
  holds, even if nothing new is on GitHub yet. The installed commit is
  recorded in `/boot/nightfall/source-sha`. A build installed before that file
  existed shows as `(unrecorded)` until its next update.
- **The previous kernel is kept.** `update nightfall` keeps the kernel and boot
  image it replaces as `vmlinuz.previous` and `initramfs.img.previous`, as a
  matched pair. To go back, copy them over the live files from Nightfall's
  shell or a rescue boot.
- **Panel options are your call.** If Nightfall's entry carries `i915.*`
  options this boot lacks, the update stops instead of silently dropping them.
  The GUI then asks **Keep them** or **Drop them**. On the command line:
  `update nightfall --nightfall-cmdline "<options>"` keeps them, and
  `--nightfall-cmdline ""` drops them.

The GUI checks for updates in the background each time it opens, and shows an
**Updates** section only when something is behind.

---

## Hardware fixes (Pixel Slate)

```
nightfall-toolkit status          # what this machine needs
nightfall-toolkit list -v         # every fix, with what it does and its risks
nightfall-toolkit apply <id>      # install one
nightfall-toolkit verify <id>     # is it still working?
nightfall-toolkit revert <id>     # undo it
nightfall-toolkit logs [<id>]     # a fix's own log, for those that keep one
nightfall-toolkit selftest [<id>] # check the from-source fixes still build; installs nothing

nightfall-toolkit apply --kernel list        # which kernels are installed
nightfall-toolkit apply <id> -k <version>    # target a specific kernel
```

Nothing is applied unless you name it (or pass `--all`) **and** the fix's own
detection says the problem is present on this machine. High-risk fixes make
you type the fix id to confirm, because a `y/N` prompt is too easy to answer by
reflex for something that can lock the machine.

`--kernel` matters only for fixes that build kernel modules. It helps when the
running kernel has no headers but another installed one does: you build for
that one, and the fix takes effect when you boot it.

### What is covered

21 fixes. Apart from Nightfall, they are matched to Chromebook hardware.

**Camera:** `camera-orientation`, `ipu3-camera`, `ipu3-imgu-grableak`, `ipu3-imgu-iommu`, `ipu3-vcm-focus`

**Screen, brightness and rotation:** `accelerometer-orientation`, `backlight-permissions`, `display-autorotate`, `panel-brightness-aux`, `panel-brightness-dpcd`, `tablet-mode-switch`

**Audio:** `audio-avs-dsp`

**Buttons and sensors:** `ec-buttons-poll`, `touch-resume-rebind`

**Login and security:** `cros-fp-fingerprint`

**Booting and recovery:** `nightfall`, `nightfall-default`

**Android (Waydroid):** `waydroid-lxc-hook`, `waydroid-netfilter`, `waydroid-usb`

**System and performance:** `zram-swap`

Two of these exist nowhere else as far as I know: the IPU3 camera stack, and a
bridge that makes the fingerprint reader in the power button work with GNOME's
lock screen. The fingerprint fix builds from source; if Rust is not installed,
it installs it for your user only (checksum-verified, no root), removable later
with `rustup self uninstall`.

On another Chromebook, most fixes should simply report "not needed". That is
reasoning, not evidence: only the Pixel Slate has been tested.

### Getting the IPU3 cameras working

**You do not need to rebuild a kernel.**

```
nightfall-toolkit apply ipu3-imgu-iommu   # adds iommu=pt
sudo reboot
nightfall-toolkit apply ipu3-camera       # now builds the hardware path
```

The IPU3's hardware image processor only needs its device in an IOMMU
passthrough domain, and a boot parameter does that.

Order matters. Applying `ipu3-camera` first gets you the **software** image
processor, which works and cannot lock the machine, but uses most of a CPU core
and has no autofocus. The tool warns you before that happens, and re-running it
after the IOMMU fix switches to hardware automatically.

---

## How a fix works

Each fix is a directory under `fixes/` with a `fix.yaml` and up to four scripts:

| script | meaning |
|---|---|
| `detect.sh` | exit 0 = the problem is present here; 1 = not needed; 2 = can't tell |
| `verify.sh` | exit 0 = our fix is in place and working; 3 = the desired state holds, but something other than this fix achieved it |
| `apply.sh`  | install it |
| `revert.sh` | undo it |

**`detect` and `verify` answer different questions**, and keeping them apart is
deliberate. "The problem exists" and "our fix is installed" are not the same
thing. Conflating them means you cannot notice that a distro update fixed
something upstream, or that a package upgrade silently clobbered your fix.

**Exit 3 exists because "the machine is fine" is not the same as "we fixed
it".** The IPU3 IOMMU fix found this the hard way. Mainline carries a VT-d quirk
that puts the Intel IPU in a passthrough domain by itself, so on a stock kernel
the fix's `verify` saw a safe `identity` domain and reported **applied**, on a
machine whose bootloader it had never touched. Exit 3 reports *not needed*
instead, and leaves Apply disabled, since there is nothing to add.

Write `verify` to check **the thing your fix installs** (your file, your
marker, your parameter), not the symptom being gone. Where the symptom can also
vanish on its own, say so with exit 3.

`category` in `fix.yaml` decides which heading a fix appears under, in both the
CLI and the GUI:

| category | heading |
|---|---|
| `camera` | Camera |
| `display` | Screen, brightness and rotation |
| `audio` | Audio |
| `input` | Buttons and sensors |
| `security` | Login and security |
| `android` | Android (Waydroid) |
| `boot` | Booting and recovery (in the GUI: under Nightfall) |
| `system` | System and performance |

Anything unrecognised falls under **Other**, which is a prompt to add a
category rather than a place to leave things.

`fix.yaml` declares metadata and, crucially, hazards:

```yaml
id: some-fix
category: camera            # decides the heading it appears under
name: Human readable name
risk: low | medium | high
reverts_cleanly: true
applies_to:
  chromebook: true          # coreboot or GOOG* ACPI devices present
  product: "nocturne|eve"   # case-insensitive regex against DMI
danger: |
  Specific, earned warnings. What can actually go wrong, on what hardware,
  and what it looked like when it did.
```

Absent `applies_to` criteria mean "any machine". Matching is regex so a fix can
target a family without enumerating every spelling.

## Writing a fix

Guidelines that matter more than they look:

- **Resolve devices by name, never by number.** `/dev/v4l-subdev*` numbering is
  not stable across reboots. It moved twice in one day on the Pixel Slate and
  produced wrong readings both times. Use `lib/find-subdev.sh`.
- **Detect the actual condition, not the hardware.** "This is a Nocturne" is a
  weak reason to change something; "this kernel cannot load `ip_tables` and
  Waydroid's script requires it" is a good one.
- **Back up before overwriting**, and make `revert` restore from that backup.
- **Kernel-level fixes should be detect-only.** Ship the patch, detect whether
  the running kernel has it, and tell the user. A tool that rewrites your
  bootloader unprompted is not a tool worth trusting.
- **Beware `cmd | grep -q` under `set -o pipefail`.** `grep -q` exits at the
  first match, the producer takes SIGPIPE, and pipefail then reports the whole
  pipeline as failed *even though the match succeeded*. This silently made a
  verify script misreport which image processor was in use. Capture output to
  a variable first, then match against it.
- **Escalate with `$SUDO`, never a bare `sudo`.** Every script starts with
  `SUDO="${FIXER_SUDO:-sudo}"`. In a terminal that is plain `sudo`. Under the
  GUI, which has no terminal, it becomes `pkexec`, so the desktop's polkit
  agent authenticates however the machine is set up to: on a Pixel Slate, the
  fingerprint reader. A bare `sudo` under the GUI dies with *"sudo: A terminal
  is required to authenticate"*. This applies to shared library code too:
  `lib/kernel-cmdline.sh` is used by every command-line fix, so one bare
  `sudo` in it breaks all of them.
- **Batch root work into a single `$SUDO`.** pkexec's polkit action is
  `auth_admin`, not `auth_admin_keep`, so there is no credential cache: every
  `$SUDO` is another authentication prompt. One since-removed fix fired nine,
  spread across a build that takes minutes. Put the whole privileged sequence
  in one `$SUDO bash -s -- "$A" "$B" <<'ROOT'` block.
- **Keep `$SUDO` out of pipelines.** `echo x | $SUDO tee f` escalates in a
  forked subshell, which can prompt again. Write to a temp file and
  `$SUDO install` it, or use `$SUDO tee f <<< "x"`.
- **Never assume `/usr/sbin` is on `PATH`.** Debian does not put it there for a
  normal user, so `command -v kexec` fails even when kexec is installed.
- **Write the `danger` field from experience.** Generic caution teaches nobody
  anything; "this locked the machine three times and left the boot filesystem
  dirty" tells someone exactly how much care to take.

## Layout

```
bin/nightfall-toolkit      CLI
bin/nightfall-toolkit-gui  GTK4 / libadwaita app
lib/registry.py            fix discovery, DMI matching, lifecycle
lib/updates.sh             update checks and fast-forward pulls
lib/kernels.sh             kernel listing, install, removal, command lines
lib/nightfall-backups.sh   Nightfall backup listing and deletion
lib/boot-menu.sh           Nightfall and GRUB boot settings
lib/find-subdev.sh         resolve media devices by name
fixes/<id>/                one directory per fix
daemon/                    background helpers some fixes install
kernel/                    kernel patches (shipped, not applied)
tests/                     fixture-only tests, run in CI; no root or real hardware
```

## Status

Usable, and used daily on a Pixel Slate. Two things to know before you rely on
it:

- **It is tested on very few machines.** Nightfall on two, the hardware fixes
  on one. Detection is written to be conservative, but your hardware will
  differ in ways nobody here has seen.
- **Some fixes can hard-lock a machine.** That is documented per fix in the
  `danger` field, written from what actually happened.

## Licence

GPL-3.0-or-later. See [LICENSE](LICENSE).

Contributions are welcome, particularly fixes for machines other than the
Pixel Slate. Adding a machine is data plus a detect script rather than a
rewrite: see **Writing a fix** above, and please write the `danger` field from
something you actually observed.
