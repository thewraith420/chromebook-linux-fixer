# SPDX-License-Identifier: GPL-3.0-or-later
"""Fix registry: discovery, hardware matching and state for chromebook-fixer.

A "fix" is a directory under fixes/ containing a fix.yaml plus up to four
executables: detect, apply, verify, revert.

    detect   exit 0 -> this machine NEEDS the fix (the problem is present)
             exit 1 -> not needed / already handled elsewhere
             exit 2 -> cannot tell
    verify   exit 0 -> the fix is currently in place and working
    apply    install it
    revert   undo it

Keeping detect and verify separate matters: "the problem exists" and "our fix
is installed" are different questions, and conflating them makes it impossible
to notice that a distro update fixed something upstream, or that our fix was
silently clobbered.
"""

from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
FIXES_DIR = REPO / "fixes"
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME",
                                Path.home() / ".local/state")) / "chromebook-fixer"

RISK_ORDER = {"low": 0, "medium": 1, "high": 2}


def dmi(field_name: str) -> str:
    """Read a DMI field, or '' if unavailable."""
    try:
        return (Path("/sys/class/dmi/id") / field_name).read_text().strip()
    except OSError:
        return ""


@dataclass(frozen=True)
class Machine:
    vendor: str
    product: str
    board: str
    bios_vendor: str
    bios_version: str
    kernel: str

    @classmethod
    def detect(cls) -> "Machine":
        return cls(
            vendor=dmi("sys_vendor"),
            product=dmi("product_name"),
            board=dmi("board_name"),
            bios_vendor=dmi("bios_vendor"),
            bios_version=dmi("bios_version"),
            kernel=os.uname().release,
        )

    @property
    def is_chromebook(self) -> bool:
        """
        Chromebooks running a third-party firmware such as MrChromebox still
        report coreboot, and retain the GOOG* ACPI devices. Either signal alone
        is weak; DMI vendor is unreliable because reflashed machines report the
        OEM rather than Google.
        """
        if "coreboot" in self.bios_vendor.lower():
            return True
        return any(d.startswith("GOOG")
                   for d in os.listdir("/sys/bus/platform/devices"))

    def describe(self) -> str:
        return (f"{self.vendor} {self.product}"
                f" (board {self.board}, {self.bios_vendor} {self.bios_version})")


@dataclass
class Fix:
    id: str
    path: Path
    name: str
    description: str = ""
    risk: str = "medium"
    applies_to: dict = field(default_factory=dict)
    needs_root: bool = False
    notes: str = ""
    danger: str = ""
    reverts_cleanly: bool = True
    # Fixes that should be applied first to get the best outcome. Not hard
    # prerequisites: a fix must still work without them, just less well.
    prefers: list = field(default_factory=list)

    @classmethod
    def load(cls, path: Path) -> "Fix | None":
        meta_file = path / "fix.yaml"
        if not meta_file.is_file():
            return None
        meta = yaml.safe_load(meta_file.read_text()) or {}
        return cls(
            id=meta.get("id", path.name),
            path=path,
            name=meta.get("name", path.name),
            description=meta.get("description", "").strip(),
            risk=meta.get("risk", "medium"),
            applies_to=meta.get("applies_to") or {},
            needs_root=bool(meta.get("needs_root", False)),
            notes=(meta.get("notes") or "").strip(),
            danger=(meta.get("danger") or "").strip(),
            reverts_cleanly=bool(meta.get("reverts_cleanly", True)),
            prefers=list(meta.get("prefers") or []),
        )

    # -- hardware matching -------------------------------------------------

    def matches(self, machine: Machine) -> bool:
        """
        Whether this fix is intended for this machine.

        Absent criteria mean "any" - a fix with no applies_to is generic. Every
        criterion present must match, and matching is case-insensitive regex on
        the DMI string so a fix can target a family ("nocturne|eve") without
        enumerating every spelling.
        """
        rules = self.applies_to
        if not rules:
            return True

        if rules.get("chromebook") and not machine.is_chromebook:
            return False

        for key, attr in (("product", "product"), ("board", "board"),
                          ("vendor", "vendor")):
            pattern = rules.get(key)
            if pattern and not re.search(pattern, getattr(machine, attr),
                                         re.IGNORECASE):
                return False

        return True

    # -- lifecycle ---------------------------------------------------------

    def _script(self, action: str) -> Path | None:
        script = self.path / f"{action}.sh"
        return script if script.is_file() and os.access(script, os.X_OK) else None

    def has(self, action: str) -> bool:
        return self._script(action) is not None

    def run(self, action: str, capture: bool = True) -> tuple[int, str]:
        """Run one lifecycle script. Returns (exit code, combined output)."""
        script = self._script(action)
        if script is None:
            return 127, f"no {action} script"

        env = dict(os.environ)
        env["FIX_DIR"] = str(self.path)
        env["FIXER_REPO"] = str(REPO)
        env["FIX_ID"] = self.id

        # Scripts use "$SUDO", never a bare "sudo", so that escalation works
        # both in a terminal and under the GUI. See sudo_command().
        cmd, askpass = sudo_command()
        env["FIXER_SUDO"] = cmd
        if askpass:
            env["SUDO_ASKPASS"] = askpass

        try:
            proc = subprocess.run(
                [str(script)], env=env, timeout=1800,
                capture_output=capture, text=True)
        except subprocess.TimeoutExpired:
            return 124, "timed out"
        out = ""
        if capture:
            out = (proc.stdout or "") + (proc.stderr or "")
        return proc.returncode, out.strip()

    # -- status ------------------------------------------------------------

    def status(self) -> tuple[str, str]:
        """
        Returns (state, detail) where state is one of:
            applied     verify says the fix is in place
            needed      detect says the problem is present, fix not applied
            ok          the problem is not present (nothing to do)
            unknown     could not determine
        """
        if self.has("verify"):
            code, out = self.run("verify")
            if code == 0:
                return "applied", out
            if code == 3:
                # "The desired state holds, but this fix is not what achieved
                # it" - a kernel quirk, an upstream change, or the distro
                # already doing the right thing. Reporting "applied" here would
                # credit the tool for a change it never made, and would leave a
                # user believing their bootloader had been edited when it had
                # not. Treat it as nothing-to-do and skip detect.
                return "ok", out
        if self.has("detect"):
            code, out = self.run("detect")
            if code == 0:
                return "needed", out
            if code == 1:
                return "ok", out
            return "unknown", out
        return "unknown", "no detect script"


ASKPASS_HELPERS = (
    "/usr/bin/ssh-askpass",
    "/usr/bin/ssh-askpass-gnome",
    "/usr/libexec/openssh/gnome-ssh-askpass",
    "/usr/lib/ssh/x11-ssh-askpass",
    "/usr/bin/lxqt-openssh-askpass",
)


def _has_terminal() -> bool:
    """Can a fix script prompt for a password on a terminal?"""
    if os.environ.get("FIXER_NO_TTY"):
        return False                      # the GUI says so explicitly
    try:
        fd = os.open("/dev/tty", os.O_RDONLY)
    except OSError:
        return False
    os.close(fd)
    return True


def _find_askpass() -> str | None:
    existing = os.environ.get("SUDO_ASKPASS")
    if existing and Path(existing).exists():
        return existing
    return next((h for h in ASKPASS_HELPERS if Path(h).exists()), None)


def sudo_command() -> tuple[str, str | None]:
    """
    Decide how fix scripts should escalate, as (command, askpass helper).

    sudo consults SUDO_ASKPASS *only* when invoked as `sudo -A`. Setting the
    variable alone does nothing, so a script running under the GUI - which has
    no controlling terminal - fails with "sudo: A terminal is required to
    authenticate" no matter what the environment says.

    In a real terminal plain `sudo` is the right answer: prompting on the tty
    is what the user expects, and forcing -A there would demand a graphical
    askpass helper for an ordinary CLI run, including over ssh.
    """
    if _has_terminal():
        return "sudo", None
    askpass = _find_askpass()
    if askpass:
        return "sudo -A", askpass
    # No terminal and no helper. Leave plain sudo so the user sees sudo's own
    # diagnosis rather than a silent difference in behaviour.
    return "sudo", None


def load_fixes() -> list[Fix]:
    if not FIXES_DIR.is_dir():
        return []
    found = [Fix.load(p) for p in sorted(FIXES_DIR.iterdir()) if p.is_dir()]
    fixes = [f for f in found if f]
    fixes.sort(key=lambda f: (RISK_ORDER.get(f.risk, 1), f.id))
    return fixes
