# SPDX-License-Identifier: GPL-3.0-or-later
"""Machine specs for the GUI's Machine Specs section.

Every reader takes its source path as an argument so tests can feed fixture
files, and every one returns "" (or None) rather than raising: a spec that
cannot be read is left out, never shown as an error.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

# Board codenames that are better known by their product name.
CODENAMES = {"nocturne": "Pixel Slate"}


def _read(path) -> str:
    try:
        return Path(path).read_text(errors="replace")
    except OSError:
        return ""


def _gb(kib: float) -> str:
    gb = kib / 1024 / 1024
    return f"{gb:.0f} GB" if gb >= 100 else f"{gb:.1f} GB"


def _looks_like_sku(name: str) -> bool:
    # Lenovo's product_name is a model code ("82XV", "20XW0055US"); the
    # recognisable name is in product_version / product_family instead.
    return bool(re.fullmatch(r"[0-9A-Z]{4,12}", name)) and any(c.isdigit() for c in name)


def _vendor(name: str) -> str:
    # "LENOVO" -> "Lenovo"; short all-caps brands ("HP", "ASUS") are left alone.
    return name.capitalize() if name.isupper() and len(name) > 4 else name


def model_name(vendor: str, product: str, version: str = "", family: str = "") -> str:
    name = product
    if _looks_like_sku(product):
        for candidate in (version, family):
            if candidate and candidate.lower() not in ("none", "default string"):
                name = candidate
                break
    name = CODENAMES.get(name.lower(), name)
    vendor = _vendor(vendor)
    if vendor and not name.lower().startswith(vendor.lower()):
        name = f"{vendor} {name}"
    return name.strip()


def cpu(cpuinfo="/proc/cpuinfo") -> tuple[str, str]:
    """(full description, short name for a summary), or ("", "")."""
    text = _read(cpuinfo)
    m = re.search(r"^model name\s*:\s*(.+)$", text, re.M)
    if not m:
        return "", ""
    name = re.sub(r"\((R|TM|tm|r)\)", "", m.group(1))
    name = re.sub(r"\s+CPU\b|\s+Processor\b|\s*@\s*[\d.]+\s*GHz", "", name)
    name = re.sub(r"\s+\d+-Core\b", "", name)
    name = " ".join(name.split())
    threads = len(re.findall(r"^processor\s*:", text, re.M))
    cores, phys = set(), "0"
    for line in text.splitlines():
        if line.startswith("physical id"):
            phys = line.split(":", 1)[1].strip()
        elif line.startswith("core id"):
            cores.add((phys, line.split(":", 1)[1].strip()))
    counts = []
    if cores:
        counts.append(f"{len(cores)} core{'s' if len(cores) != 1 else ''}")
    if threads:
        counts.append(f"{threads} thread{'s' if threads != 1 else ''}")
    full = name + (f" · {', '.join(counts)}" if counts else "")
    short = re.sub(r"^\d+(st|nd|rd|th) Gen\s+", "", name)
    short = re.sub(r"^(Intel|AMD)\s+", "", short).split(" w/ ")[0]
    return full, short


def memory(meminfo="/proc/meminfo", swaps="/proc/swaps") -> tuple[str, str]:
    """(full description, RAM alone for a summary), or ("", "")."""
    m = re.search(r"^MemTotal:\s*(\d+)\s*kB", _read(meminfo), re.M)
    if not m:
        return "", ""
    ram = _gb(int(m.group(1)))
    swap_kib, kinds = 0, []
    for line in _read(swaps).splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 3 and parts[2].isdigit():
            swap_kib += int(parts[2])
            if "zram" in parts[0] and "zram" not in kinds:
                kinds.append("zram")
    full = f"{ram} usable"
    if swap_kib:
        full += f" · {_gb(swap_kib)} swap" + (" (includes zram)" if kinds else "")
    return full, f"{ram} RAM"


def storage(path="/") -> str:
    try:
        st = os.statvfs(path)
    except OSError:
        return ""
    total = st.f_blocks * st.f_frsize / 1024
    free = st.f_bavail * st.f_frsize / 1024
    if not total:
        return ""
    return f"{_gb(free)} free of {_gb(total)} on the system drive"


def os_name(os_release="/etc/os-release") -> str:
    m = re.search(r'^PRETTY_NAME="?([^"\n]+)"?', _read(os_release), re.M)
    return m.group(1) if m else ""


def desktop(env=None) -> str:
    env = os.environ if env is None else env
    name = env.get("XDG_CURRENT_DESKTOP", "").split(":")[-1]
    if not name:
        return ""
    if name == "GNOME" and shutil.which("gnome-shell"):
        try:
            out = subprocess.run(["gnome-shell", "--version"], capture_output=True,
                                 text=True, timeout=5).stdout
            m = re.search(r"([\d]+)(\.[\d.]+)?", out)
            if m:
                name = f"GNOME {m.group(1)}"
        except (OSError, subprocess.SubprocessError):
            pass
    session = env.get("XDG_SESSION_TYPE", "")
    return f"{name} · {session.capitalize() if session != 'x11' else 'X11'}" if session else name


def graphics(lspci_output: str | None = None) -> str:
    """GPU names from `lspci -mm`, e.g. "Intel UHD Graphics, NVIDIA GeForce RTX 3050"."""
    if lspci_output is None:
        if not shutil.which("lspci"):
            return ""
        try:
            lspci_output = subprocess.run(["lspci", "-mm"], capture_output=True,
                                          text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return ""
    names = []
    for line in lspci_output.splitlines():
        fields = re.findall(r'"([^"]*)"', line)
        if len(fields) < 3 or fields[0] not in (
                "VGA compatible controller", "3D controller", "Display controller"):
            continue
        vendor, device = fields[1], fields[2]
        bracket = re.search(r"\[([^\]]+)\]", vendor)
        vendor = bracket.group(1).split("/")[0] if bracket else vendor.split()[0]
        bracket = re.search(r"\[([^\]]+)\]", device)
        device = bracket.group(1) if bracket else device
        if not device.lower().startswith(vendor.lower()):
            device = f"{vendor} {device}"
        names.append(device)
    return ", ".join(names)


def firmware(bios_vendor: str, bios_version: str, efi_dir="/sys/firmware/efi") -> str:
    if not bios_version:
        return ""
    parts = [f"{_vendor(bios_vendor)} {bios_version}".strip()]
    efi = Path(efi_dir)
    if efi.is_dir():
        boot = "UEFI"
        sb = next(iter(sorted((efi / "efivars").glob("SecureBoot-*"))), None) \
            if (efi / "efivars").is_dir() else None
        if sb is not None:
            try:
                boot += ", Secure Boot " + ("on" if sb.read_bytes()[-1:] == b"\x01" else "off")
            except OSError:
                pass
        parts.append(boot)
    else:
        parts.append("legacy BIOS boot")
    return " · ".join(parts)


def gather(machine) -> tuple[str, str, list[tuple[str, str]]]:
    """(model name, one-line summary, [(label, value), ...]) for this machine."""
    model = model_name(machine.vendor, machine.product,
                       getattr(machine, "product_version", ""), machine.product_family)
    cpu_full, cpu_short = cpu()
    mem_full, mem_short = memory()
    rows = [
        ("Processor", cpu_full),
        ("Memory", mem_full),
        ("Graphics", graphics()),
        ("Storage", storage()),
        ("Operating System", os_name()),
        ("Desktop", desktop()),
        ("Kernel", machine.kernel),
        ("Firmware", firmware(machine.bios_vendor, machine.bios_version)),
    ]
    summary = " · ".join(x for x in (cpu_short, mem_short, machine.kernel) if x)
    return model, summary, [(k, v) for k, v in rows if v]
