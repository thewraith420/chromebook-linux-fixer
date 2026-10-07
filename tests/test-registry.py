#!/usr/bin/env python3
# lib/registry.py's Machine.describe() - the only thing under test here.
# No fixtures needed: Machine is a plain frozen dataclass, so every case is
# just constructing one directly and reading the string back.
#
# What this guards: product_name is a vendor-internal model/SKU code
# ("82XV" on a real Lenovo LOQ, 2026-10-02) that nobody recognizes: Bob's own
# reaction to seeing it as Machine Specs' whole "Model" line was "what's with
# the model" - GNOME's own About panel, reading product_family instead,
# showed "Lenovo LOQ 15IRH8" for the identical machine. describe() now
# prefers product_family when it adds real information, but Fix.matches()
# keys on `product` (product_name) - that field, and every existing
# applies_to: {product: "..."} rule across every fix, must never change.
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
from registry import Machine  # noqa: E402

pass_ = 0
fail = 0


def expect(name, got, want):
    global pass_, fail
    if got == want:
        pass_ += 1
    else:
        fail += 1
        print(f"FAIL  {name}  (want {want!r}, got {got!r})")


def machine(**kw):
    base = dict(vendor="V", product="P", board="B", bios_vendor="BV",
                bios_version="1.0", kernel="1.0", product_family="")
    base.update(kw)
    return Machine(**base)


# ---- the real bug: a friendlier commercial name should lead -------------
m = machine(vendor="LENOVO", product="82XV", board="LNVNB161216",
           bios_vendor="LENOVO", bios_version="N3HET19W",
           product_family="LOQ 15IRH8")
expect("product_family leads, raw product_name kept alongside",
       m.describe(),
       "LENOVO LOQ 15IRH8 (82XV) (board LNVNB161216, LENOVO N3HET19W)")

# ---- the common case: no product_family set (most Chromebooks) - the
# exact old format, byte for byte, must survive unchanged ------------------
m = machine(vendor="Google", product="Nocturne", board="Nocturne",
           bios_vendor="coreboot", bios_version="26.06", product_family="")
expect("no product_family: identical to the pre-fix format",
       m.describe(), "Google Nocturne (board Nocturne, coreboot 26.06)")

# ---- product_family present but identical to product_name: no redundant
# parenthetical repeating the same string -----------------------------------
m = machine(vendor="Dell", product="XPS 13", board="0ABC",
           bios_vendor="Dell", bios_version="1.0", product_family="XPS 13")
expect("product_family == product_name: falls back, no redundant '(XPS 13)'",
       m.describe(), "Dell XPS 13 (board 0ABC, Dell 1.0)")

# ---- a family that just repeats the model, decorated: the real Pixel Slate
# (MrChromebox 2609) reports product_family "Google_Nocturne" ---------------
m = machine(vendor="Google", product="Nocturne", board="Nocturne",
           bios_vendor="coreboot", bios_version="MrChromebox-2609.0",
           product_family="Google_Nocturne")
expect("product_family containing product_name: not repeated",
       m.describe(), "Google Nocturne (board Nocturne, coreboot MrChromebox-2609.0)")

# ---- `product` (the matching field) is never touched by any of the above -
for pf in ("", "LOQ 15IRH8", "82XV"):
    m = machine(product="82XV", product_family=pf)
    expect(f"product stays the raw product_name regardless (product_family={pf!r})",
           m.product, "82XV")

print(f"{pass_} passed, {fail} failed")
sys.exit(1 if fail else 0)
