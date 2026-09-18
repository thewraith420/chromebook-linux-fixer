#!/bin/bash
# lib/kernels.sh against a fake /boot and /lib/modules. This is the code in
# this repo that can leave a machine unable to boot, so most of these cases are
# about what it REFUSES: the running kernel, the last kernel, a name that is
# not a kernel. Nothing here touches the real system - every path is redirected
# and dpkg/apt/update-grub are stubs that record what they were asked to do.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K="${K:-$REPO/lib/kernels.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0

BOOT="$T/boot"; MODS="$T/modules"; BIN="$T/bin"
mkdir -p "$BOOT/grub" "$MODS" "$BIN"

# --- stubs: record the call, never touch anything real ----------------------
cat > "$BIN/dpkg" <<'STUB'
#!/bin/bash
# Only -S is used. A release with "generic" in it is packaged here.
[ "${1:-}" = -S ] || exit 1
case "$2" in
    *generic*) echo "linux-image-${2##*/vmlinuz-}: $2" ;;
    *) echo "dpkg-query: no path found matching pattern $2" >&2; exit 1 ;;
esac
STUB
cat > "$BIN/dpkg-query" <<'STUB'
#!/bin/bash
# -W -f '${Package} ${Status}\n' <pattern>
pattern="${!#}"; rel=${pattern//\*/}
case "$rel" in
    *generic*) printf 'linux-image-%s install ok installed\nlinux-modules-%s install ok installed\nnot-a-kernel-%s install ok installed\n' "$rel" "$rel" "$rel" ;;
esac
STUB
cat > "$BIN/apt-get" <<'STUB'
#!/bin/bash
echo "apt-get $*" >> "$APT_LOG"
STUB
cat > "$BIN/update-grub" <<'STUB'
#!/bin/bash
echo "update-grub ran" >> "$GRUB_LOG"
STUB
chmod +x "$BIN"/*
export PATH="$BIN:$PATH" APT_LOG="$T/apt.log" GRUB_LOG="$T/grub.log"
export FIXER_SUDO=env FIXER_BOOT_DIR="$BOOT" FIXER_MODULES_DIR="$MODS"
export NF_DEFAULT_FILE="$BOOT/nightfall-default" FIXER_GRUB_CFG="$BOOT/grub/grub.cfg"
export FIXER_RUNNING_KERNEL=7.2.3-BobZKernel

expect() { local name="$1" want="$2"; shift 2
    "$@" >/dev/null 2>&1; local got=$?
    if [ "$got" = "$want" ]; then pass=$((pass+1))
    else fail=$((fail+1)); echo "FAIL  $name  (want $want, got $got)"; fi; }
says()   { local name="$1" pat="$2"; shift 2
    local out; out=$("$@" 2>&1)
    if grep -q -- "$pat" <<< "$out"; then pass=$((pass+1))
    else fail=$((fail+1)); echo "FAIL  $name  (no '$pat')"; fi; }
lacks()  { local name="$1" pat="$2"; shift 2
    local out; out=$("$@" 2>&1)
    if grep -q -- "$pat" <<< "$out"; then fail=$((fail+1)); echo "FAIL  $name  ('$pat' should not appear)"
    else pass=$((pass+1)); fi; }
holds()  { local name="$1"; shift
    if [ "$@" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL  $name"; fi; }

kernel() {  # kernel <release> [kb]
    local r="$1" kb="${2:-64}"
    head -c $((kb * 1024)) /dev/zero > "$BOOT/vmlinuz-$r"
    head -c $((kb * 1024)) /dev/zero > "$BOOT/initrd.img-$r"
    mkdir -p "$MODS/$r"; head -c $((kb * 1024)) /dev/zero > "$MODS/$r/mod.ko"
}
reset_all() {
    rm -rf "$BOOT" "$MODS"; mkdir -p "$BOOT/grub" "$MODS"
    kernel 7.2.3-BobZKernel; kernel 7.2.2-BobZKernel; kernel 7.0.0-31-generic
    mkdir -p "$MODS/7.0.0-27-generic"; head -c 4096 /dev/zero > "$MODS/7.0.0-27-generic/old.ko"
    printf 'menuentry x {\n\tlinux\t/boot/vmlinuz-7.2.3-BobZKernel root=/dev/x\n}\n' > "$BOOT/grub/grub.cfg"
    : > "$APT_LOG"; : > "$GRUB_LOG"
}
reset_all

# ---- the view --------------------------------------------------------------
says  "lists an installed kernel"        "7.2.3-BobZKernel"   "$K" list
says  "marks the running one"            "running"            "$K" list
says  "names the owning package"         "linux-image-7.0.0-31-generic" "$K" list
says  "says when one was hand-installed" "installed by hand"  "$K" list
says  "shows leftover modules"           "modules with no kernel" "$K" list
says  "names the leftover"               "7.0.0-27-generic"   "$K" list
holds "tab output is one line each"      "$("$K" list --tab | wc -l)" = 4
says  "tab marks orphan module trees"    "	modules$"         "$K" list --tab

# ---- Nightfall's default ---------------------------------------------------
says   "reports no default at first"     "No default set"     "$K" default --show
expect "sets a default"                  0 "$K" default 7.2.3-BobZKernel
says   "  uses grub.cfg's own path"      "^/boot/vmlinuz-7.2.3-BobZKernel$" cat "$BOOT/nightfall-default"
says   "  and reports it"                "7.2.3-BobZKernel"   "$K" default --show
says   "list marks the default"          "default"            "$K" list
expect "refuses a kernel that is absent" 1 "$K" default 9.9.9-nope
expect "refuses a path as a release"     1 "$K" default ../../etc/passwd
# A kernel GRUB has not listed yet is still a fair choice: fall back to the
# computed path rather than refusing.
expect "falls back when grub has no entry" 0 "$K" default 7.2.2-BobZKernel
says   "  computed path written"         "vmlinuz-7.2.2-BobZKernel$" cat "$BOOT/nightfall-default"
expect "clears the default"              0 "$K" default --clear
holds  "  the marker is gone"            ! -e "$BOOT/nightfall-default"
expect "clearing again is fine"          0 "$K" default --clear

# ---- removal: the refusals first -------------------------------------------
expect "refuses the running kernel"      1 "$K" remove 7.2.3-BobZKernel
holds  "  it is still there"             -f "$BOOT/vmlinuz-7.2.3-BobZKernel"
expect "refuses a kernel that is absent" 1 "$K" remove 9.9.9-nope
expect "refuses a path as a release"     1 "$K" remove ../../etc/passwd
says   "explains the running refusal"    "boot another one first" "$K" remove 7.2.3-BobZKernel

# ---- removal: hand-installed ------------------------------------------------
expect "removes a hand-installed kernel" 0 "$K" remove 7.2.2-BobZKernel
holds  "  vmlinuz gone"                  ! -e "$BOOT/vmlinuz-7.2.2-BobZKernel"
holds  "  initrd gone"                   ! -e "$BOOT/initrd.img-7.2.2-BobZKernel"
holds  "  modules gone"                  ! -d "$MODS/7.2.2-BobZKernel"
says   "  update-grub ran"               "update-grub ran"    cat "$GRUB_LOG"
lacks  "  apt was not involved"          "apt-get"            cat "$APT_LOG"
holds  "  other kernels untouched"       -f "$BOOT/vmlinuz-7.2.3-BobZKernel"

# ---- removal: packaged goes through apt ------------------------------------
reset_all
expect "removes a packaged kernel"       0 "$K" remove 7.0.0-31-generic
says   "  apt-get remove --purge"        "apt-get -y remove --purge" cat "$APT_LOG"
says   "  the image package"             "linux-image-7.0.0-31-generic" cat "$APT_LOG"
says   "  and the modules package"       "linux-modules-7.0.0-31-generic" cat "$APT_LOG"
lacks  "  but nothing unrelated"         "not-a-kernel"       cat "$APT_LOG"
holds  "  files left to apt, not deleted here" -f "$BOOT/vmlinuz-7.0.0-31-generic"

# ---- removal clears a default that pointed at it ---------------------------
reset_all
"$K" default 7.2.2-BobZKernel >/dev/null 2>&1
expect "removes the defaulted kernel"    0 "$K" remove 7.2.2-BobZKernel
holds  "  the marker went with it"       ! -e "$BOOT/nightfall-default"
reset_all
"$K" default 7.2.3-BobZKernel >/dev/null 2>&1
expect "removes a different kernel"      0 "$K" remove 7.2.2-BobZKernel
holds  "  the marker survived"           -f "$BOOT/nightfall-default"

# ---- leftover module trees --------------------------------------------------
reset_all
expect "removes leftover modules"        0 "$K" remove 7.0.0-27-generic
holds  "  they are gone"                 ! -d "$MODS/7.0.0-27-generic"
lacks  "  without calling apt"           "apt-get"            cat "$APT_LOG"

# ---- the last kernel must survive ------------------------------------------
rm -rf "$BOOT" "$MODS"; mkdir -p "$BOOT/grub" "$MODS"
kernel 7.2.2-BobZKernel      # one kernel, and not the running one
expect "refuses to remove the only kernel" 1 "$K" remove 7.2.2-BobZKernel
holds  "  it is still there"             -f "$BOOT/vmlinuz-7.2.2-BobZKernel"
says   "  and says why"                  "nothing to boot" "$K" remove 7.2.2-BobZKernel

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
