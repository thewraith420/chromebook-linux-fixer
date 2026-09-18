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
cat > "$BIN/depmod" <<'STUB'
#!/bin/bash
echo "depmod $*" >> "$DEPMOD_LOG"
STUB
cat > "$BIN/update-initramfs" <<'STUB'
#!/bin/bash
# Logs first, THEN decides whether to fail - a stub whose failure path is the
# last command run has its own exit status silently become the script's,
# whether or not that was ever the intent. Learned by tripping over it here.
echo "update-initramfs $*" >> "$INITRAMFS_LOG"
if [ -n "${FAIL_INITRAMFS:-}" ]; then exit 1; fi
exit 0
STUB
chmod +x "$BIN"/*
export PATH="$BIN:$PATH" APT_LOG="$T/apt.log" GRUB_LOG="$T/grub.log"
export DEPMOD_LOG="$T/depmod.log" INITRAMFS_LOG="$T/initramfs.log"
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


# ---- install: a separate fixture tree ---------------------------------------
# Every archive path is boot/... and lib/modules/<release>/..., matching the
# real BobZKernel and Nightfall tarball layout - so, unlike $BOOT/$MODS above,
# these have to share one parent for install-root extraction to land where
# list/remove/default then look for it.
IROOT="$T/install-root"
IBOOT="$IROOT/boot"; IMODS="$IROOT/lib/modules"
# A function, not `env ...` - env cannot invoke a shell function. Reads
# FIXER_RUNNING_KERNEL from the caller if set (a `VAR=x run_install ...`
# prefix reaches a function's environment same as it would a command), so the
# running-kernel warning test can override it without needing env at all.
run_install() { env FIXER_BOOT_DIR="$IBOOT" FIXER_MODULES_DIR="$IMODS" \
    NF_DEFAULT_FILE="$IBOOT/nightfall-default" FIXER_GRUB_CFG="$IBOOT/grub/grub.cfg" \
    FIXER_INSTALL_ROOT="$IROOT" \
    FIXER_RUNNING_KERNEL="${FIXER_RUNNING_KERNEL:-7.2.3-BobZKernel}" "$K" "$@"; }
reset_install() {
    rm -rf "$IROOT"; mkdir -p "$IBOOT/grub" "$IMODS"
    # FIXER_GRUB_CFG (set below) points at boot/grub/grub.cfg, same as the
    # real Slate - not boot/grub.cfg, which install would then find nothing at
    # and silently fall back to a computed path instead of grub.cfg's own.
    printf 'menuentry x {\n\tlinux\t/boot/vmlinuz-9.9.9-test root=/dev/x\n}\n' > "$IBOOT/grub/grub.cfg"
    : > "$DEPMOD_LOG"; : > "$INITRAMFS_LOG"; : > "$GRUB_LOG"
}

# A minimal but real tarball: boot/{vmlinuz,System.map,config}-<release> and
# lib/modules/<release>/, the same shape create-portable-installer produces.
SRC="$T/src"; mkdir -p "$SRC/boot" "$SRC/lib/modules/9.9.9-test/kernel"
head -c 4000 /dev/zero > "$SRC/boot/vmlinuz-9.9.9-test"
head -c 200  /dev/zero > "$SRC/boot/System.map-9.9.9-test"
head -c 50   /dev/zero > "$SRC/boot/config-9.9.9-test"
head -c 800  /dev/zero > "$SRC/lib/modules/9.9.9-test/kernel/test.ko"
head -c 10   /dev/zero > "$SRC/lib/modules/9.9.9-test/modules.dep"
GOOD="$T/good.tar.gz"
( cd "$SRC" && tar czf "$GOOD" ./boot ./lib )

# No boot/vmlinuz-* inside at all.
NOKERNEL="$T/nokernel.tar.gz"; echo hi > "$T/notes.txt"
tar czf "$NOKERNEL" -C "$T" notes.txt

# A valid vmlinuz entry (so the release parses), plus a member elsewhere in
# lib/modules/<release>/ that climbs out via '..' - the case the traversal
# guard exists for. Real breakage, not a synthetic pattern: this is what a
# hostile or merely corrupt tarball looks like from the inside.
mkdir -p "$T/evil/boot" "$T/evil-payload"
head -c 10 /dev/zero > "$T/evil/boot/vmlinuz-9.9.9-evil"
echo pwned > "$T/evil-payload/file"
( cd "$T/evil" && tar cf "$T/evil.tar" ./boot )
tar --transform 's#^evil-payload#lib/modules/9.9.9-evil/../../../../../../tmp/kernels-test-escape#' \
    -rf "$T/evil.tar" -C "$T" evil-payload/file
gzip -f "$T/evil.tar"

reset_install
expect "install: a real kernel tarball"  0 run_install install "$GOOD" --default
holds  "  vmlinuz landed"                -f "$IBOOT/vmlinuz-9.9.9-test"
holds  "  System.map landed"             -f "$IBOOT/System.map-9.9.9-test"
holds  "  modules landed"                -f "$IMODS/9.9.9-test/kernel/test.ko"
says   "  depmod ran for this release"   "depmod -a 9.9.9-test" cat "$DEPMOD_LOG"
says   "  update-initramfs ran"          "update-initramfs -c -k 9.9.9-test" cat "$INITRAMFS_LOG"
says   "  update-grub ran"               "update-grub ran"    cat "$GRUB_LOG"
says   "  default marker set from grub.cfg's own path" "^/boot/vmlinuz-9.9.9-test$" cat "$IBOOT/nightfall-default"

expect "install: reinstalling is allowed" 0 run_install install "$GOOD"
says   "  and says so"                    "already installed" run_install install "$GOOD"

expect "install: refuses a tarball with no kernel in it" 1 run_install install "$NOKERNEL"

expect "install: refuses a traversal member" 1 run_install install "$T/evil.tar.gz"
holds  "  nothing escaped to /tmp"       ! -e /tmp/kernels-test-escape
rm -rf /tmp/kernels-test-escape 2>/dev/null || true

expect "install: refuses a tarball that does not exist" 1 run_install install "$T/nope.tar.gz"

# A separate helper, not `FIXER_RUNNING_KERNEL=x run_install ...`: run_install
# is a shell function, and while a bare var-assignment prefix does reach a
# function's environment, it cannot be split across expect()/says()'s own
# "$@" forwarding the way an external command's argv can.
run_install_running() {
    local running="$1"; shift
    env FIXER_BOOT_DIR="$IBOOT" FIXER_MODULES_DIR="$IMODS" \
        NF_DEFAULT_FILE="$IBOOT/nightfall-default" FIXER_GRUB_CFG="$IBOOT/grub/grub.cfg" \
        FIXER_INSTALL_ROOT="$IROOT" FIXER_RUNNING_KERNEL="$running" "$K" "$@"
}
run_install_failing() {   # exercises the update-initramfs stub's FAIL_INITRAMFS path
    env FIXER_BOOT_DIR="$IBOOT" FIXER_MODULES_DIR="$IMODS" \
        NF_DEFAULT_FILE="$IBOOT/nightfall-default" FIXER_GRUB_CFG="$IBOOT/grub/grub.cfg" \
        FIXER_INSTALL_ROOT="$IROOT" FIXER_RUNNING_KERNEL=7.2.3-BobZKernel \
        FAIL_INITRAMFS=1 "$K" "$@"
}
reset_install
says "install: warns before overwriting the running kernel" "WARNING" \
     run_install_running 9.9.9-test install "$GOOD"
expect "  but still allows it"           0 run_install_running 9.9.9-test install "$GOOD"

reset_install
# A var-assignment prefix on the function itself, no env wrapper: run_install
# is a function, not something env can exec, but its own body execs an
# external `env ... "$K" ...`, which inherits whatever is exported in ITS
# caller's environment when the function runs - including this.
expect "install: an initramfs failure is reported, not silently ok" 1 \
       run_install_failing install "$GOOD"
says   "  says the kernel is not bootable" "NOT bootable" \
       run_install_failing install "$GOOD"
holds  "  its files are still on disk (not rolled back)" -f "$IBOOT/vmlinuz-9.9.9-test"
holds  "  but no default was set"        ! -e "$IBOOT/nightfall-default"
unset FAIL_INITRAMFS

# A space check that never refuses is not a space check - df here reports
# almost nothing free, on a real filesystem (not a stub of tar or install
# itself), so this exercises the actual member-size accounting.
reset_install
FAKE_DF="$BIN/df"
cat > "$FAKE_DF" <<'STUB'
#!/bin/bash
# Less than $GOOD needs (~5KB uncompressed) but not 0, so this tests the
# comparison rather than an emptiness check.
echo "Filesystem 1K-blocks Used Available Use% Mounted"
echo "fake       1000      998  2         99% $2"
STUB
chmod +x "$FAKE_DF"
expect "install: refuses when free space is too low" 1 run_install install "$GOOD"
says   "  and says how much it needed"   "need about" run_install install "$GOOD"
holds  "  nothing was written"           ! -e "$IBOOT/vmlinuz-9.9.9-test"
rm -f "$FAKE_DF"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
