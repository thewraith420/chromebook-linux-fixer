#!/usr/bin/env python3
# lib/specs.py against fixture files: no dependence on the machine running it.
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
import specs  # noqa: E402

pass_ = 0
fail = 0


def expect(name, got, want):
    global pass_, fail
    if got == want:
        pass_ += 1
    else:
        fail += 1
        print(f"FAIL  {name}  (want {want!r}, got {got!r})")


T = Path(tempfile.mkdtemp())


def fixture(name, text):
    p = T / name
    p.write_text(text)
    return p


# ---- model name ------------------------------------------------------------
expect("Lenovo: SKU code replaced by the product version, vendor not shouted",
       specs.model_name("LENOVO", "82XV", "LOQ 15IRH8", "LOQ 15IRH8"), "Lenovo LOQ 15IRH8")
expect("Lenovo: SKU with no version falls back to the family",
       specs.model_name("LENOVO", "20XW0055US", "", "ThinkPad X1 Carbon Gen 9"),
       "Lenovo ThinkPad X1 Carbon Gen 9")
expect("Pixel Slate: codename shown as the product name (family not used)",
       specs.model_name("Google", "Nocturne", "", "Google_Nocturne"), "Google Pixel Slate")
expect("Dell: a real product name is kept, not swapped for the family",
       specs.model_name("Dell Inc.", "XPS 13 9310", "", "XPS"), "Dell Inc. XPS 13 9310")
expect("HP: short all-caps brand kept, not repeated",
       specs.model_name("HP", "HP Laptop 15-fd0xxx", "", ""), "HP Laptop 15-fd0xxx")

# ---- CPU ---------------------------------------------------------------------
raptor = fixture("cpuinfo-raptor", "".join(
    f"processor\t: {i}\nmodel name\t: 13th Gen Intel(R) Core(TM) i5-13420H\n"
    f"physical id\t: 0\ncore id\t\t: {i // 2}\n\n" for i in range(4)))
expect("Intel: (R)/(TM) dropped, cores and threads counted",
       specs.cpu(raptor), ("13th Gen Intel Core i5-13420H · 2 cores, 4 threads", "Core i5-13420H"))
slate = fixture("cpuinfo-slate", "processor\t: 0\nmodel name\t: Intel(R) Core(TM) i5-8200Y CPU @ 1.30GHz\n")
expect("Intel: 'CPU @ GHz' dropped; no core ids means threads only",
       specs.cpu(slate), ("Intel Core i5-8200Y · 1 thread", "Core i5-8200Y"))
amd = fixture("cpuinfo-amd", "processor\t: 0\nmodel name\t: AMD Ryzen 7 7840HS w/ Radeon 780M Graphics\n"
                             "physical id\t: 0\ncore id\t\t: 0\n")
expect("AMD: summary name stops before the integrated graphics",
       specs.cpu(amd)[1], "Ryzen 7 7840HS")
expect("missing cpuinfo: nothing, not an error", specs.cpu(T / "nope"), ("", ""))

# ---- memory ------------------------------------------------------------------
meminfo = fixture("meminfo", "MemTotal:        7809776 kB\nMemFree:  100 kB\n")
swaps = fixture("swaps", "Filename\tType\tSize\tUsed\tPriority\n"
                         "/dev/nvme0n1p3 partition 8104956 0 10\n/dev/zram0 partition 3904884 0 100\n")
expect("RAM and total swap, zram noted",
       specs.memory(meminfo, swaps), ("7.4 GB usable · 11.5 GB swap (includes zram)", "7.4 GB RAM"))
expect("no swap: RAM only", specs.memory(meminfo, T / "nope"), ("7.4 GB usable", "7.4 GB RAM"))
expect("missing meminfo: nothing", specs.memory(T / "nope", swaps), ("", ""))
expect("sizes of 100 GB and over drop the decimal", specs._gb(929.3 * 1024 * 1024), "929 GB")

# ---- OS, desktop -------------------------------------------------------------
expect("os-release PRETTY_NAME",
       specs.os_name(fixture("os-release", 'NAME="Debian GNU/Linux"\nPRETTY_NAME="Debian GNU/Linux 13 (trixie)"\n')),
       "Debian GNU/Linux 13 (trixie)")
expect("desktop and session type",
       specs.desktop({"XDG_CURRENT_DESKTOP": "KDE", "XDG_SESSION_TYPE": "x11"}), "KDE · X11")
expect("no desktop: nothing", specs.desktop({}), "")

# ---- graphics ----------------------------------------------------------------
lspci = (
    '00:02.0 "VGA compatible controller" "Intel Corporation" "Raptor Lake-P [UHD Graphics]" -r04 "Lenovo" "Device 3c90"\n'
    '01:00.0 "VGA compatible controller" "NVIDIA Corporation" "GA107BM / GN20-P0-R-K2 [GeForce RTX 3050 6GB Laptop GPU]" -ra1 "Lenovo" "Device 3c90"\n'
    '00:14.0 "USB controller" "Intel Corporation" "Alder Lake USB" -r01 "Lenovo" "x"\n')
expect("Intel + NVIDIA from lspci, short names, other devices ignored",
       specs.graphics(lspci), "Intel UHD Graphics, NVIDIA GeForce RTX 3050 6GB Laptop GPU")
expect("AMD vendor bracket shortened",
       specs.graphics('c5:00.0 "Display controller" "Advanced Micro Devices, Inc. [AMD/ATI]" "Phoenix1 [Radeon 780M]" -rc4 "x" "y"\n'),
       "AMD Radeon 780M")

# ---- firmware ----------------------------------------------------------------
efi = T / "efi"
(efi / "efivars").mkdir(parents=True)
sb = efi / "efivars" / "SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
sb.write_bytes(b"\x06\x00\x00\x00\x00")
expect("UEFI, Secure Boot off", specs.firmware("LENOVO", "LZCN39WW", efi),
       "Lenovo LZCN39WW · UEFI, Secure Boot off")
sb.write_bytes(b"\x06\x00\x00\x00\x01")
expect("Secure Boot on", specs.firmware("LENOVO", "LZCN39WW", efi),
       "Lenovo LZCN39WW · UEFI, Secure Boot on")
expect("no EFI directory: legacy boot",
       specs.firmware("coreboot", "MrChromebox-2609.0", T / "no-efi"),
       "coreboot MrChromebox-2609.0 · legacy BIOS boot")

print(f"{pass_} passed, {fail} failed")
sys.exit(1 if fail else 0)
