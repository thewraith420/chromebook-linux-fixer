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
    # dpkg's own "rc" state (removed, config-files remain) - what `apt
    # remove` without --purge leaves behind. Modelled on a real one: Software
    # Updater left linux-modules-7.0.0-31-generic exactly like this.
    *rcleft*) printf 'linux-image-%s deinstall ok config-files\nlinux-modules-%s deinstall ok config-files\n' "$rel" "$rel" ;;
    # The narrow linux-image-* listing rc_only_releases() itself makes -
    # pattern strips to exactly "linux-image-". A release with no files
    # anywhere left (rc state only), one with real companion packages (see
    # the zfs case below), and an ordinary installed one as a red herring -
    # none of the companion packages themselves appear here, deliberately,
    # even for releases that have them below: they must never surface as
    # their own release.
    linux-image-) [ -n "${DPKGONLY_FIXTURE:-}" ] && printf 'linux-image-7.0.0-99-dpkgonly-generic deinstall ok config-files\nlinux-image-7.0.0-28-zfs-generic deinstall ok config-files\nlinux-image-7.0.0-31-generic install ok installed\n'; true ;;
    *7.0.0-28-zfs-generic*) printf 'linux-image-7.0.0-28-zfs-generic deinstall ok config-files\nlinux-modules-7.0.0-28-zfs-generic deinstall ok config-files\nlinux-main-modules-zfs-7.0.0-28-zfs-generic deinstall ok config-files\n' ;;
    # The SAME release, now queried individually by rc_packages_for() (as
    # cmd_list/cmd_remove do once rc_only_releases() has named it) - must
    # still read as rc state here too, ahead of the generic *generic* case
    # below, which this release's name would otherwise also match.
    *7.0.0-99-dpkgonly-generic*) printf 'linux-image-7.0.0-99-dpkgonly-generic deinstall ok config-files\nlinux-modules-7.0.0-99-dpkgonly-generic deinstall ok config-files\n' ;;
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
# "installed by hand" is a guess from "no dpkg owner" alone, wrong for a
# kernel the fixer itself had installed (Bob, 2026-10-02) - dropped in
# favour of saying nothing about install method. "-" is what fills the
# owner column for an unowned kernel now (reset_all's 7.2.3-BobZKernel).
lacks "never claims a kernel was 'installed by hand' - a guess it cannot back up" \
      "installed by hand" "$K" list
says  "an unowned kernel's owner column is a plain dash, not blank or a guess" \
      '7\.2\.3-BobZKernel.*[^-]-$' "$K" list
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

# ---- leftover modules still owned by dpkg (rc state): purge, don't rm -rf --
reset_all
mkdir -p "$MODS/7.0.0-31-rcleft-generic"
says   "listing says removed but not purged, names the owner" \
       "removed but not purged by apt" "$K" list
says   "  and the owning package"        "linux-image-7.0.0-31-rcleft-generic" "$K" list
holds  "tab output carries the rc package in the 3rd field" \
       "$("$K" list --tab | grep 7.0.0-31-rcleft-generic | cut -f3)" =        "linux-image-7.0.0-31-rcleft-generic,linux-modules-7.0.0-31-rcleft-generic"
: > "$APT_LOG"
expect "remove purges through apt rather than deleting by hand" 0 "$K" remove 7.0.0-31-rcleft-generic
says   "  purges exactly the rc-state packages"  "apt-get -y purge linux-image-7.0.0-31-rcleft-generic linux-modules-7.0.0-31-rcleft-generic" cat "$APT_LOG"
says   "  says it purged, not just removed"      "purged" "$K" remove 7.0.0-31-rcleft-generic

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

# ==== per-kernel cmdline overrides (/boot/nightfall-cmdline) ================
# Format confirmed with the nightfall-boot-manager session, 2026-10-02 -
# these fixtures match their real source, not assumptions: a missing line is
# no override (passes grub.cfg's own entry through untouched), the key must
# be an exact match of grub.cfg's own "linux" directive column 2 (no path
# reconstruction), comments/blank lines are skipped, the LAST matching line
# wins on a duplicate, and an empty value after the tab is never an override.
CMDFILE="$BOOT/nightfall-cmdline"
cmdline() { NF_CMDLINE_FILE="$CMDFILE" "$K" cmdline "$@"; }

reset_all
says   "cmdline show: no override reads GRUB's own entry" "root=/dev/x" cmdline 7.2.3-BobZKernel
expect "  and reports needing root for it" 0 cmdline 7.2.3-BobZKernel

expect "cmdline set: refuses an empty value"        1 cmdline 7.2.3-BobZKernel --set ""
says   "  and says why"                              "refusing to save an empty" cmdline 7.2.3-BobZKernel --set ""
expect "cmdline set: refuses a value with no root="  1 cmdline 7.2.3-BobZKernel --set "quiet splash"
says   "  and says why"                              "no root=" cmdline 7.2.3-BobZKernel --set "quiet splash"
holds  "  neither refusal wrote anything"            ! -e "$CMDFILE"

expect "cmdline set: a normal value succeeds"        0 cmdline 7.2.3-BobZKernel --set "root=/dev/x quiet splash"
holds  "  the key is exactly grub.cfg's own path, not reconstructed" \
       "$(cut -f1 "$CMDFILE")" = "/boot/vmlinuz-7.2.3-BobZKernel"
says   "cmdline show: the saved override, not GRUB's entry" "quiet splash" cmdline 7.2.3-BobZKernel
lacks  "  and does not need root once saved (no 'needs root' note)" \
       "needs root" cmdline 7.2.3-BobZKernel

# re-setting must not stack a second line for the same kernel
expect "cmdline set again: still just one line"      0 cmdline 7.2.3-BobZKernel --set "root=/dev/x quiet nosplash"
holds  "  exactly one line for this kernel"          "$(grep -c vmlinuz-7.2.3-BobZKernel "$CMDFILE")" = 1
says   "  the newest value is in effect (last wins)" "nosplash" cmdline 7.2.3-BobZKernel

expect "cmdline reset: clears it"                    0 cmdline 7.2.3-BobZKernel --reset
says   "  falls back to GRUB's own entry again"       "root=/dev/x" cmdline 7.2.3-BobZKernel
expect "cmdline reset again: no-op, not an error"     0 cmdline 7.2.3-BobZKernel --reset
says   "  says there was nothing to reset"            "nothing to reset" cmdline 7.2.3-BobZKernel --reset

# ---- no hid_google_hammer guard: deliberately removed (Bob, 2026-10-02) -
# the override only affects boots through Nightfall, and GRUB's own entries
# still boot generic with the blacklist regardless, so dropping it here is
# recoverable without a confirmation step in the way. Only the hard refusals
# (empty, no root=, a literal tab - tested elsewhere) still apply. ----------
reset_all
printf 'menuentry x {\n\tlinux\t/boot/vmlinuz-7.2.3-BobZKernel root=/dev/x module_blacklist=hid_google_hammer\n}\n' > "$BOOT/grub/grub.cfg"
expect "cmdline set: dropping the hammer blacklist is allowed, no guard" 0 \
       cmdline 7.2.3-BobZKernel --set "root=/dev/x quiet"
holds  "  and it was actually saved"                  "$(cat "$CMDFILE")" = \
       "$(printf '/boot/vmlinuz-7.2.3-BobZKernel\troot=/dev/x quiet')"
expect "--force is gone entirely - an unrecognised flag, not a silent no-op" 1 \
       cmdline 7.2.3-BobZKernel --set "root=/dev/x quiet" --force

# ---- format edge cases, read directly against a hand-written file ---------
reset_all
printf '# a comment line, and a blank line below\n\n/boot/vmlinuz-7.2.3-BobZKernel\tfirst value\n/boot/vmlinuz-7.2.3-BobZKernel\tlast value wins' > "$CMDFILE"
says   "comments and blank lines are skipped, no crash" "last value wins" cmdline 7.2.3-BobZKernel
says   "a file with no trailing newline still parses"   "last value wins" cmdline 7.2.3-BobZKernel
printf '/boot/vmlinuz-7.2.3-BobZKernel\t\n' > "$CMDFILE"
says   "an empty value after the tab is never an override" "root=/dev/x" cmdline 7.2.3-BobZKernel

# ---- the separate-/boot key convention: no reconstruction, use grub.cfg's
# own literal string verbatim, whatever shape it has -----------------------
reset_all
printf 'menuentry x {\n\tlinux\t/vmlinuz-7.2.3-BobZKernel root=/dev/x\n}\n' > "$BOOT/grub/grub.cfg"
expect "cmdline set: picks up grub.cfg's own key shape" 0 cmdline 7.2.3-BobZKernel --set "root=/dev/x quiet"
holds  "  bare /vmlinuz-X, not /boot/vmlinuz-X - not reconstructed" \
       "$(cut -f1 "$CMDFILE")" = "/vmlinuz-7.2.3-BobZKernel"

# ---- orphans: a saved override for a kernel that is gone -------------------
reset_all
printf '/boot/vmlinuz-9.9.9-removed-long-ago\troot=/dev/old\n' > "$CMDFILE"
says  "list flags an orphaned cmdline override"        "no matching kernel" "$K" list
says  "  names the stale key"                           "9.9.9-removed-long-ago" "$K" list
says  "tab output marks it orphan/cmdline"               "orphan	cmdline" "$K" list --tab
# Real bug, seen live (Slate session, 2026-10-02): a blank first column reads
# as a continuation of whichever row printed immediately before it (that is
# how this function's own flags line is written), so the orphan line looked
# like it belonged to the last kernel listed rather than being its own row.
holds "  the orphan line is not a blank-prefixed continuation" \
      -n "$("$K" list | grep 'no matching kernel' | grep -v '^[[:space:]]*$' | awk '{print $1}')"
# the no-/boot-prefix convention is also checked, under $BOOT
printf '/vmlinuz-9.9.9-also-gone\troot=/dev/old\n' > "$CMDFILE"
says  "  works for the no-/boot-prefix convention too"   "9.9.9-also-gone" "$K" list
# a key that DOES resolve to a real file is not flagged - the test's own
# $BOOT stands in for the real /boot (see cmdline_orphans' own comment on
# why the check substitutes $BOOT rather than a literal "/boot" prefix)
printf '%s\troot=/dev/x\n' "$BOOT/vmlinuz-7.2.3-BobZKernel" > "$CMDFILE"
lacks "  a key matching a real kernel is not flagged"    "no matching kernel" "$K" list

# the main listing flags which kernels carry a saved override
reset_all
printf '/boot/vmlinuz-7.2.3-BobZKernel\troot=/dev/x quiet\n' > "$CMDFILE"
says  "list flags the kernel that has an override"       "cmdline-override" "$K" list
holds "  tab output carries the flag too"                -n "$("$K" list --tab | grep 7.2.3-BobZKernel | grep cmdline-override)"

# ---- removal prunes the matching line, every path --------------------------
reset_all
printf '/boot/vmlinuz-7.2.2-BobZKernel\troot=/dev/x\n' > "$CMDFILE"
expect "remove (hand-installed) prunes its cmdline override" 0 "$K" remove 7.2.2-BobZKernel
holds  "  the line is gone"                              ! -s "$CMDFILE"
holds  "  a backup of the cmdline file was kept"          -f "$CMDFILE.chromebook-fixer.bak"

reset_all
printf '/boot/vmlinuz-7.0.0-31-generic\troot=/dev/x\n' > "$CMDFILE"
expect "remove (packaged) prunes its cmdline override"   0 "$K" remove 7.0.0-31-generic
holds  "  the line is gone"                              ! -s "$CMDFILE"

reset_all
printf '/boot/vmlinuz-7.0.0-27-generic\troot=/dev/x\n' > "$CMDFILE"
expect "remove (leftover modules) prunes its cmdline override" 0 "$K" remove 7.0.0-27-generic
holds  "  the line is gone"                              ! -s "$CMDFILE"

reset_all
mkdir -p "$MODS/7.0.0-31-rcleft-generic"
printf '/boot/vmlinuz-7.0.0-31-rcleft-generic\troot=/dev/x\n' > "$CMDFILE"
expect "remove (rc-state orphan, purged via apt) prunes its cmdline override" 0 "$K" remove 7.0.0-31-rcleft-generic
holds  "  the line is gone"                              ! -s "$CMDFILE"

# a release with NO saved override must not touch the file at all
reset_all
printf '/boot/vmlinuz-7.2.3-BobZKernel\troot=/dev/x\n' > "$CMDFILE"
"$K" remove 7.2.2-BobZKernel >/dev/null 2>&1
holds  "remove leaves an unrelated kernel's override untouched" \
       "$(cat "$CMDFILE")" = "$(printf '/boot/vmlinuz-7.2.3-BobZKernel\troot=/dev/x')"

# ---- dpkg-only orphans: rc-state packages with NO files left anywhere -----
# Real case, Slate session 2026-10-02: /lib/modules/<release> deleted by
# hand after the kernel itself was already gone, but dpkg still has three
# rc-state packages for it - invisible to orphan_modules() (nothing under
# $MODULES to find) and to a plain removal attempt (nothing under $BOOT
# either), until rc_only_releases() asks dpkg directly instead of starting
# from what is on disk.
reset_all
export DPKGONLY_FIXTURE=1
says  "list surfaces a dpkg-only orphan (no files anywhere)" \
      "7.0.0-99-dpkgonly-generic" "$K" list
says  "  says no files remain, not 'leftovers'"            "no files remain" "$K" list
says  "  names the owning packages"                         "linux-image-7.0.0-99-dpkgonly-generic" "$K" list
says  "tab output marks it orphan/modules, like a real leftover dir" \
      "orphan	modules" "$K" list --tab
holds "  and carries the owning packages in the 3rd tab field" \
      "$("$K" list --tab | grep 7.0.0-99-dpkgonly-generic | cut -f3)" = \
      "linux-image-7.0.0-99-dpkgonly-generic,linux-modules-7.0.0-99-dpkgonly-generic"
lacks "  a normally-installed kernel is not swept up by the broad dpkg query" \
      "7.0.0-31-generic.*no files remain" "$K" list

expect "remove purges a dpkg-only orphan through apt" 0 \
       "$K" remove 7.0.0-99-dpkgonly-generic
says   "  says no files remain rather than claiming a directory was removed" \
       "no files remain" "$K" remove 7.0.0-99-dpkgonly-generic
: > "$APT_LOG"
"$K" remove 7.0.0-99-dpkgonly-generic >/dev/null 2>&1
says   "  purges exactly its own rc-state packages" \
       "apt-get -y purge linux-image-7.0.0-99-dpkgonly-generic linux-modules-7.0.0-99-dpkgonly-generic" \
       cat "$APT_LOG"
expect "a release with genuinely nothing (no files, no dpkg entry) still refuses" 1 \
       "$K" remove 9.9.9-nothing-at-all-generic
says   "  and says why"  "nothing removed" "$K" remove 9.9.9-nothing-at-all-generic

# ---- a companion package (e.g. ZFS modules) must never surface as its own
# bogus "release" - real bug, Slate session 2026-10-02:
# linux-main-modules-zfs-7.0.0-27-generic matched no prefix in an earlier,
# fixed-prefix-list version of rc_only_releases() and was reported (and
# purgeable) as if it were itself a kernel release, duplicating what its
# real release's row already correctly swept up. -----------------------------
says  "a zfs companion package does not appear as its own release row" \
      "7.0.0-28-zfs-generic" "$K" list
holds "  exactly one row for the real release, not one per companion package" \
      "$("$K" list --tab | grep -c 7.0.0-28-zfs-generic)" = 1
holds "  the companion package name itself is never column 1 (its own 'release')" \
      "$("$K" list --tab | cut -f1 | grep -c '^linux-main-modules-zfs-')" = 0
says  "  the real release's row lists every companion package, zfs included" \
      "linux-main-modules-zfs-7.0.0-28-zfs-generic" "$K" list
lacks "  no double space before 'still owns it' (plain echo, not tr)" \
      "  still owns it" "$K" list
expect "remove on the real release purges every companion package together" 0 \
       "$K" remove 7.0.0-28-zfs-generic
: > "$APT_LOG"
"$K" remove 7.0.0-28-zfs-generic >/dev/null 2>&1
holds "  exactly one purge call, not one per package"  "$(grep -c '^apt-get -y purge' "$APT_LOG")" = 1
says  "  the zfs package is purged alongside the rest, in one call" \
      "linux-main-modules-zfs-7.0.0-28-zfs-generic" cat "$APT_LOG"
says  "  the image package too"                        "linux-image-7.0.0-28-zfs-generic" cat "$APT_LOG"
says  "  and the plain modules package"                 "linux-modules-7.0.0-28-zfs-generic" cat "$APT_LOG"
unset DPKGONLY_FIXTURE

# ---- pruning a cmdline-only orphan: no kernel, no modules, no dpkg entry,
# just a dangling line in nightfall-cmdline. Real case, Slate session
# 2026-10-02: Bob could neither `remove` nor `cmdline --reset` a line like
# this - both died on "no vmlinuz" before ever reaching the file. ----------
reset_all
printf '/boot/vmlinuz-9.9.9-dangling-generic\troot=/dev/old\n' > "$CMDFILE"

expect "cmdline --reset works on a release with no vmlinuz at all" 0 \
       cmdline 9.9.9-dangling-generic --reset
holds  "  the line is gone"                              ! -s "$CMDFILE"
holds  "  a backup was kept"                              -f "$CMDFILE.chromebook-fixer.bak"

printf '/boot/vmlinuz-9.9.9-dangling-generic\troot=/dev/old\n' > "$CMDFILE"
expect "cmdline --show on a release with no vmlinuz still refuses" 1 \
       cmdline 9.9.9-dangling-generic
expect "cmdline --set on a release with no vmlinuz still refuses" 1 \
       cmdline 9.9.9-dangling-generic --set "root=/dev/x"
holds  "  neither touched the override"                   "$(cat "$CMDFILE")" = \
       "$(printf '/boot/vmlinuz-9.9.9-dangling-generic\troot=/dev/old')"

expect "kernels remove also prunes a cmdline-only orphan" 0 \
       "$K" remove 9.9.9-dangling-generic
holds  "  the line is gone"                               ! -s "$CMDFILE"
says   "  says only the override was removed, not files"  "cmdline override only" \
       bash -c 'printf "/boot/vmlinuz-9.9.9-dangling-generic\troot=/dev/old\n" > "'"$CMDFILE"'"; "'"$K"'" remove 9.9.9-dangling-generic'

reset_all
expect "a release with genuinely nothing anywhere still refuses via remove" 1 \
       "$K" remove 9.9.9-truly-nothing
says   "  and names everything it looked for"             "dpkg entry or saved cmdline" \
       "$K" remove 9.9.9-truly-nothing

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
