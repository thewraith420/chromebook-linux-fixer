# chromebook-fixer

Hardware enablement fixes for Chromebooks running Linux.

Chromebooks are good hardware that Linux distributions support badly. The
cameras, sensors, audio and power behaviour tend to depend on data that lives in
ChromeOS firmware blobs, vendor kernel trees, or nowhere at all. This tool
collects the fixes for that, and — importantly — can tell you whether each one
is actually needed on your machine before it changes anything.

---

## ⚠ Read this before using it

**This tool makes low-level changes to your system.**

Depending on the fix, that can mean replacing system libraries, editing udev
rules, patching files owned by other packages, or changing kernel behaviour.

Some of these fixes touch hardware that is poorly supported on Linux. **A bad
interaction can hard lock the machine**, requiring a forced power-off — which
can corrupt a filesystem or lose unsaved work. That is not hypothetical: the
IPU3 camera work behind this tool locked the reference machine solid three
times, with no kernel panic and nothing written to any log.

**It is developed and tested on exactly one machine** (Google Nocturne, the
Pixel Slate). Every fix is gated on hardware detection, but detection is
imperfect and your hardware will differ in ways the author has never seen.

**There is no warranty.** You are responsible for your own machine.

Sensible precautions:

- Read what a fix does first: `chromebook-fixer list -v`
- Save your work before applying anything marked **HIGH RISK**
- Prefer applying one fix at a time over `--all`
- Check `reverts_cleanly` — a few fixes cannot be cleanly undone

You will be asked to acknowledge this once, before the first `apply`.

## Getting the hardware ISP working (IPU3 cameras)

The short version: **you do not need to rebuild a kernel.**

```
chromebook-fixer apply ipu3-imgu-iommu   # adds iommu=pt
sudo reboot
chromebook-fixer apply ipu3-camera       # now builds the HARDWARE path
```

The IPU3 hardware ISP only needs its device placed in an IOMMU passthrough
domain, and a boot parameter does that. A per-device kernel quirk is tidier and
needs no parameter, but it is an optimisation, not a requirement.

Order matters. Applying `ipu3-camera` on a machine whose ImgU is still in a
translated domain gets you the **software ISP** — which works, and cannot lock
the machine, but costs most of a CPU core and has no autofocus. The tool warns
you before that happens, and re-running after the IOMMU fix switches to
hardware automatically.

---

## Usage

```
chromebook-fixer status          # what this machine needs
chromebook-fixer list -v         # every known fix, with descriptions
chromebook-fixer apply <id>      # install one
chromebook-fixer verify <id>     # is it still working?
chromebook-fixer revert <id>     # undo it

chromebook-fixer apply --kernel list        # which kernels are installed
chromebook-fixer apply <id> -k <version>    # target a specific kernel
```

`--kernel` matters only for fixes that build or replace kernel modules;
everything else ignores it. It is useful when the kernel you are running has no
headers but another installed kernel does — you can build for that one, and the
fix takes effect when you boot it. The tool says so explicitly rather than
quietly producing a module that will not load.

Nothing is applied unless you ask for it by name (or pass `--all`), **and** the
fix's own detection says the problem is actually present on this machine.

High-risk fixes require you to type the fix id to confirm. A `y/N` prompt is too
easy to answer by reflex for something that can lock the machine.

---

## How a fix works

Each fix is a directory under `fixes/` with a `fix.yaml` and up to four scripts:

| script | meaning |
|---|---|
| `detect.sh` | exit 0 = the problem is present here; 1 = not needed; 2 = can't tell |
| `verify.sh` | exit 0 = our fix is in place and working |
| `apply.sh`  | install it |
| `revert.sh` | undo it |

**`detect` and `verify` answer different questions**, and keeping them apart is
deliberate. "The problem exists" and "our fix is installed" are not the same
thing — conflating them means you cannot notice that a distro update fixed
something upstream, or that a package upgrade silently clobbered your fix.

`fix.yaml` declares metadata and, crucially, hazards:

```yaml
id: some-fix
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
  not stable across reboots — it moved twice in one day on the reference
  machine and produced wrong readings both times. Use `lib/find-subdev.sh`.
- **Detect the actual condition, not the hardware.** "This is a Nocturne" is a
  weak reason to change something; "this kernel cannot load `ip_tables` and
  waydroid's script requires it" is a good one.
- **Back up before overwriting**, and make `revert` restore from that backup.
- **Kernel-level fixes should be detect-only.** Ship the patch, detect whether
  the running kernel has it, and tell the user. A tool that rewrites your
  bootloader unprompted is not a tool worth trusting.
- **Beware `cmd | grep -q` under `set -o pipefail`.** `grep -q` exits at the
  first match, the producer takes SIGPIPE, and pipefail then reports the whole
  pipeline as failed *even though the match succeeded*. This silently made a
  verify script misreport which ISP was in use. Capture output to a variable
  first, then match against it.
- **Write the `danger` field from experience.** Generic caution teaches nobody
  anything; "this locked the machine three times and left the boot filesystem
  dirty" tells someone exactly how much care to take.

## Layout

```
bin/chromebook-fixer     CLI
lib/registry.py          fix discovery, DMI matching, lifecycle
lib/find-subdev.sh       resolve media entities to device nodes by name
fixes/<id>/              one directory per fix
kernel/                  kernel patches (shipped, not applied)
```

## Status

Early. Working CLI, hardware matching, and a first set of fixes ported from
hand-rolled scripts. Contributions for other models are welcome — the fix
format is designed so that adding a model is data plus a detect script, not a
rewrite.
