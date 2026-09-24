#!/bin/bash
# fixes/nightfall/apply.sh's auto-fix path: cloning nightfall-boot-manager when
# no checkout exists, and installing missing build/boot packages - both in one
# shot each, so a fresh machine can actually apply this fix instead of being
# handed a wall of manual commands. Real reported case: a fresh Linux Mint
# install had none of it (2026-09-20).
#
# Nothing here touches the real system: PATH is a minimal, hand-picked set of
# real binaries (so a "missing" tool is genuinely absent, not merely shadowed),
# apt-get and the upstream git remote are both fixtures, and HOME is a fresh
# temp directory per run() call.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="${A:-$REPO/fixes/nightfall/apply.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0

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

# --- a minimal, real PATH: type -P (not command -v) so builtins like printf/
# true/false, which have no path, are skipped rather than producing a broken
# symlink. -----------------------------------------------------------------
BIN="$T/bin"; MINBIN="$T/minbin"; mkdir -p "$BIN" "$MINBIN"
for t in bash sh cat grep sed sort awk head tail cp mkdir rm mv readlink mktemp \
         dirname basename env tr cut wc du chmod touch git make gcc tar gzip \
         ln stat sleep kill sha256sum cmp; do
    p=$(type -P "$t" 2>/dev/null); [ -n "$p" ] && ln -s "$p" "$MINBIN/$t"
done
# Resolved NOW, against the real PATH, and handed to the apt-get stub as fixed
# paths - not re-resolved with `type -P` from inside the stub, which runs
# under the same restricted test PATH as apply.sh itself and would not find
# them (this bit the first draft of this file: every simulated "package now
# installed" symlink silently pointed at an empty target).
TRUE_REAL="$(type -P true)"; GIT_REAL="$(type -P git)"

# busybox and e2fsck complete the baseline: present from the start, so the
# "already had this one, did not re-request it" cases mean something. busybox
# is a real binary on most systems; e2fsck is not always one on a build
# machine (this one included), and its presence-or-not is not what these
# tests are about, so $TRUE_REAL stands in - `command -v e2fsck` is all
# apply.sh ever checks.
BUSYBOX_REAL="$(type -P busybox)"
[ -n "$BUSYBOX_REAL" ] && ln -s "$BUSYBOX_REAL" "$MINBIN/busybox"
ln -s "$TRUE_REAL" "$MINBIN/e2fsck"

# --- a fake picker-kernel release tarball, for the kernel-fetch stub curl to
# "download" - the real shape: boot/vmlinuz-<release> inside a gzipped tar. --
PICKER_TARBALL="$T/BobZKernel-9.9.9-picker-installer.tar.gz"
PKSRC="$T/picker_src"; mkdir -p "$PKSRC/boot"
echo "fake picker vmlinuz bytes" > "$PKSRC/boot/vmlinuz-9.9.9-BobZKernel-picker"
( cd "$PKSRC" && tar czf "$PICKER_TARBALL" ./boot )

# A canned GitHub releases API response: one picker release ahead of one
# pixel-slate release, newest first - the same shape the real feed has, so
# the "first picker match wins, the regular kernel release does not" grep in
# apply.sh is exercised against something realistic, not a synthetic single
# entry.
CURL_FAKE_API_JSON="$T/releases.json"
cat > "$CURL_FAKE_API_JSON" <<JSON
[
  {"tag_name": "v9.9.9-picker", "assets": [{"browser_download_url": "https://example.invalid/BobZKernel-9.9.9-picker-installer.tar.gz"}]},
  {"tag_name": "v9.9.9-pixel-slate", "assets": [{"browser_download_url": "https://example.invalid/BobZKernel-9.9.9-pixel-slate-installer.tar.gz"}]}
]
JSON

# --- a fake upstream repo for `git clone` to actually pull from -----------
UP="$T/upstream"; mkdir -p "$UP/boot-integration" "$UP/ui" "$UP/initramfs"
cat > "$UP/boot-integration/install-nightfall.sh" <<'EOF'
#!/bin/bash
echo "install-nightfall.sh ran: $*" >> "$LOG"
printf 'menuentry x --id nightfall {\n  linux /boot/nightfall/vmlinuz\n}\n' > "$CFG_TARGET"
EOF
cat > "$UP/ui/fetch-lvgl.sh" <<'EOF'
#!/bin/bash
echo "fetch-lvgl ran" >> "$LOG"
EOF
cat > "$UP/ui/Makefile" <<'EOF'
all:
	@echo "make ran" >> "$(LOG)"
	@touch picker && chmod +x picker
EOF
cat > "$UP/initramfs/build-initramfs.sh" <<'EOF'
#!/bin/bash
echo "build-initramfs ran" >> "$LOG"
head -c 256 /dev/zero > "$1"
EOF
chmod +x "$UP/boot-integration/install-nightfall.sh" "$UP/ui/fetch-lvgl.sh" \
         "$UP/initramfs/build-initramfs.sh"
git -C "$UP" -c init.defaultBranch=main init -q
git -C "$UP" -c user.email=t@t -c user.name=t add -A
git -C "$UP" -c user.email=t@t -c user.name=t commit -q -m x

# --- apt-get fixture: records what it was asked to install, and for the
# package names these tests exercise, makes the tool actually appear
# afterward - so a test can tell "asked for" from "asked for, and it worked".
write_working_apt_stub() {
    cat > "$BIN/apt-get" <<STUB
#!/bin/bash
echo "apt-get \$*" >> "\$APT_LOG"
[ -n "\${APT_FAIL:-}" ] && exit 1
for a in "\$@"; do
    case "\$a" in
        git)            ln -sf "$GIT_REAL"  "\$MINBIN/git" ;;
        curl)           ln -sf "\$BIN/curl" "\$MINBIN/curl" ;;
        kexec-tools)    ln -sf "$TRUE_REAL" "\$MINBIN/kexec" ;;
        busybox-static) ln -sf "$TRUE_REAL" "\$MINBIN/busybox" ;;
        fakeroot)       ln -sf "$TRUE_REAL" "\$MINBIN/fakeroot" ;;
        e2fsprogs)      ln -sf "$TRUE_REAL" "\$MINBIN/e2fsck" ;;
        cpio)           ln -sf "$TRUE_REAL" "\$MINBIN/cpio" ;;
        libdrm-dev)     mkdir -p "\$(dirname "\$NF_DRM_HEADER")"; touch "\$NF_DRM_HEADER" ;;
    esac
done
STUB
    chmod +x "$BIN/apt-get"
}
write_working_apt_stub

# curl stub: never touches the real network. Two modes, matching exactly how
# apply.sh calls it - `curl -fsSL <url>` (no -o) lists releases, `curl -fSL
# <url> -o <file>` downloads one. Which release feed and which tarball it
# serves are controlled by $CURL_FAKE_API_JSON/$CURL_FAKE_TARBALL; CURL_FAIL_*
# simulate each call failing (no network, GitHub unreachable) independently.
cat > "$BIN/curl" <<STUB
#!/bin/bash
out=""; url=""
args=("\$@")
for i in "\${!args[@]}"; do
    if [ "\${args[\$i]}" = "-o" ]; then out="\${args[\$((i+1))]}"; fi
done
for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
if [ -n "\$out" ]; then
    [ -n "\${CURL_FAIL_DOWNLOAD:-}" ] && exit 22
    cp "\${CURL_FAKE_TARBALL:-/nonexistent}" "\$out" 2>/dev/null || exit 22
elif [ "\${url##*/}" = SHA256SUMS ]; then
    cat "\${CURL_FAKE_SUMS:-/nonexistent}" 2>/dev/null || exit 22
else
    [ -n "\${CURL_FAIL_API:-}" ] && exit 22
    cat "\${CURL_FAKE_API_JSON:-/nonexistent}" 2>/dev/null || exit 22
fi
STUB
chmod +x "$BIN/curl"

FAKE_KERNEL="$T/fake-vmlinuz"; echo x > "$FAKE_KERNEL"

# A CPU that meets x86-64-v2, for every run, so nothing depends on the machine
# running the tests; the refusal case swaps in one that does not.
CPU_OK="$T/cpuinfo-v2"; CPU_OLD="$T/cpuinfo-old"
echo "flags : fpu sse sse2 pni ssse3 cx16 sse4_1 sse4_2 popcnt lahf_lm lm" > "$CPU_OK"
echo "flags : fpu sse sse2 pni ssse3 cx16 lahf_lm lm" > "$CPU_OLD"
export FIXER_CPUINFO="$CPU_OK"

# run [VAR=val ...] - a fresh $HOME every call, everything else fixed;
# extra VAR=val arguments pass straight through as further overrides. Most
# callers go through says()/lacks()/expect(), which capture run()'s output via
# $(...) - a subshell, so a plain variable assignment here would never be seen
# by the caller. Written to a file instead, which does survive it.
run() {
    local home="$T/home_$RANDOM"
    rm -rf "$home"; mkdir -p "$home"
    printf '%s' "$home" > "$T/last_home"
    env HOME="$home" PATH="$BIN:$MINBIN" FIXER_SUDO=env FIXER_REPO="$REPO" \
        NF_CLONE_URL="$UP" PROC_CMDLINE=/dev/null \
        LOG="$T/log" APT_LOG="$T/apt.log" MINBIN="$MINBIN" \
        NF_DRM_HEADER="$T/drm/drm.h" \
        CUSTOM_CFG="$home/custom.cfg" CFG_TARGET="$home/custom.cfg" \
        FIXER_NIGHTFALL_KERNEL="$FAKE_KERNEL" \
        "$@" "$A"
}
last_home() { cat "$T/last_home"; }
reset_state() {
    : > "$T/log"; : > "$T/apt.log"; rm -rf "$T/drm"; mkdir -p "$T/drm"
}
with_drm() { touch "$T/drm/drm.h"; }   # present by default unless a test removes it

# ---- auto-clone: only when nothing was found and nothing was pinned -------
reset_state; with_drm
says  "clones when no checkout exists anywhere"    "cloning it" run
holds "  it actually landed in \$HOME"              -d "$(last_home)/nightfall-boot-manager"
says  "  and the install script then ran"           "install-nightfall.sh ran" cat "$T/log"
says  "  writing the real menu entry"                "menuentry x --id nightfall" \
      cat "$(last_home)/custom.cfg"

reset_state; with_drm
# run() always uses a fresh $HOME, so cloning never persists between calls -
# simulate a pre-existing checkout directly instead of trying to reuse one.
PRE_HOME="$T/home_preexisting"; mkdir -p "$PRE_HOME"
cp -r "$UP" "$PRE_HOME/nightfall-boot-manager"
lacks "an existing checkout is never re-cloned" "cloning it" \
      env HOME="$PRE_HOME" PATH="$BIN:$MINBIN" FIXER_SUDO=env FIXER_REPO="$REPO" \
          NF_CLONE_URL="$UP" PROC_CMDLINE=/dev/null LOG="$T/log" APT_LOG="$T/apt.log" \
          MINBIN="$MINBIN" NF_DRM_HEADER="$T/drm/drm.h" \
          CUSTOM_CFG="$PRE_HOME/custom.cfg" CFG_TARGET="$PRE_HOME/custom.cfg" \
          FIXER_NIGHTFALL_KERNEL="$FAKE_KERNEL" "$A"

reset_state; with_drm
BAD_REPO="$T/nope-not-a-real-checkout"
lacks "an explicit \$FIXER_NIGHTFALL_REPO that is wrong is never auto-cloned" \
      "cloning it" run FIXER_NIGHTFALL_REPO="$BAD_REPO"
says  "  and still says checkout not found"          "checkout not found" \
      run FIXER_NIGHTFALL_REPO="$BAD_REPO"
holds "  nothing was cloned to the default location either" \
      ! -d "$(last_home)/nightfall-boot-manager"

reset_state; with_drm
expect "build-only never clones - CI should not reach for the network" \
       2 run FIXER_BUILD_ONLY=1
says  "  same 'checkout not found' message as the real path" \
      "checkout not found" run FIXER_BUILD_ONLY=1
holds "  and nothing was cloned"                    ! -d "$(last_home)/nightfall-boot-manager"

reset_state; with_drm
says  "a clone that fails falls back to the manual message" "checkout not found" \
      run NF_CLONE_URL="$T/no-such-remote"

# ---- git itself missing: installed on its own before the clone is tried ---
reset_state; with_drm
rm -f "$MINBIN/git"
run >/dev/null 2>&1
says  "installs git first when it is what's missing" "apt-get install -y git" cat "$T/apt.log"
says  "  and the clone still succeeds afterward"     "install-nightfall.sh ran" cat "$T/log"
ln -sf "$GIT_REAL" "$MINBIN/git"   # restore for the rest of the suite (apt-get's stub may already have)

# ---- package auto-install: exactly what's missing, one call ---------------
reset_state; with_drm
run >/dev/null 2>&1   # first run clones a checkout into a throwaway $HOME...
# ...but run() always uses a fresh $HOME, so point the rest of this section at
# a $HOME with a checkout already in place, the same way the "never re-clone"
# case above did, and drive it directly rather than through run().
PKG_HOME="$T/home_pkgs"; mkdir -p "$PKG_HOME"; cp -r "$UP" "$PKG_HOME/nightfall-boot-manager"
run_pkg() {
    env HOME="$PKG_HOME" PATH="$BIN:$MINBIN" FIXER_SUDO=env FIXER_REPO="$REPO" \
        NF_CLONE_URL="$UP" PROC_CMDLINE=/dev/null LOG="$T/log" APT_LOG="$T/apt.log" \
        MINBIN="$MINBIN" NF_DRM_HEADER="$T/drm/drm.h" \
        CUSTOM_CFG="$PKG_HOME/custom.cfg" CFG_TARGET="$PKG_HOME/custom.cfg" \
        FIXER_NIGHTFALL_KERNEL="$FAKE_KERNEL" "$@" "$A"
}

reset_state; with_drm
rm -f "$MINBIN/kexec" "$MINBIN/cpio"; rm -f "$T/drm/drm.h"
run_pkg >/dev/null 2>&1
says  "installs exactly the missing packages"        "apt-get install -y" cat "$T/apt.log"
says  "  names kexec-tools"                           "kexec-tools"  cat "$T/apt.log"
says  "  names cpio"                                  "cpio"         cat "$T/apt.log"
says  "  names libdrm-dev"                             "libdrm-dev"   cat "$T/apt.log"
lacks "  but not busybox-static (already present)"    "busybox-static" cat "$T/apt.log"
lacks "  but not e2fsprogs (already present)"          "e2fsprogs"    cat "$T/apt.log"
says  "  and the run still completes"                 "install-nightfall.sh ran" cat "$T/log"
holds "  exactly one apt-get install call, not several" "$(grep -c '^apt-get install' "$T/apt.log")" = 1

reset_state; with_drm
lacks "nothing missing -> apt-get never runs at all"  "apt-get install" run_pkg
holds "  apt log stayed empty"                        ! -s "$T/apt.log"

reset_state; with_drm
rm -f "$MINBIN/kexec"
cat > "$BIN/apt-get" <<'STUB'
#!/bin/bash
echo "apt-get $*" >> "$APT_LOG"
exit 1
STUB
chmod +x "$BIN/apt-get"
says  "apt-get itself failing is reported, not silently ignored" "could not install" run_pkg
lacks "  and the build never ran"                     "install-nightfall.sh ran" cat "$T/log"
write_working_apt_stub

reset_state; with_drm
rm -f "$MINBIN/kexec" "$BIN/apt-get"
says  "no apt-get at all: says so plainly, does not guess" "not an apt system" run_pkg
lacks "  and does not fabricate an apt command"       "sudo apt install" run_pkg
write_working_apt_stub
ln -sf "$TRUE_REAL" "$MINBIN/kexec"   # restore

# ---- ordering: a doomed run (no kernel, and none fetchable) must never
# touch the build/boot package install --------------------------------------
reset_state; with_drm
rm -f "$MINBIN/kexec"
NK_HOME="$T/home_nokernel"; mkdir -p "$NK_HOME"; cp -r "$UP" "$NK_HOME/nightfall-boot-manager"
env HOME="$NK_HOME" PATH="$BIN:$MINBIN" FIXER_SUDO=env FIXER_REPO="$REPO" \
    NF_CLONE_URL="$UP" PROC_CMDLINE=/dev/null LOG="$T/log" APT_LOG="$T/apt.log" \
    MINBIN="$MINBIN" NF_DRM_HEADER="$T/drm/drm.h" CURL_FAIL_API=1 \
    CUSTOM_CFG="$NK_HOME/custom.cfg" CFG_TARGET="$NK_HOME/custom.cfg" \
    "$A" >/dev/null 2>&1     # no FIXER_NIGHTFALL_KERNEL, none findable, fetch fails
lacks "no kernel (fetch failed too) -> refuses before build/boot packages" \
      "kexec-tools" cat "$T/apt.log"
ln -sf "$TRUE_REAL" "$MINBIN/kexec"

# ---- kernel auto-fetch: BobZKernel publishes prebuilt picker-kernel releases
# on GitHub - this is a fetch of an already-built artifact, the same category
# as the checkout auto-clone above, not the kernel BUILD apply.sh still
# refuses to attempt. Needs a checkout already in place (the fetched vmlinuz
# is staged inside it) and no FIXER_NIGHTFALL_KERNEL, so driven directly
# rather than through run(), which always sets one. ------------------------
KF_HOME="$T/home_kfetch"
run_kfetch() {
    # NF_FETCH_POLL_SECS near-zero: the stub curl finishes almost instantly,
    # but apply.sh's progress loop always sleeps at least one interval before
    # noticing - real seconds otherwise, times every test that fetches.
    env HOME="$KF_HOME" PATH="$BIN:$MINBIN" FIXER_SUDO=env FIXER_REPO="$REPO" \
        NF_CLONE_URL="$UP" PROC_CMDLINE=/dev/null LOG="$T/log" APT_LOG="$T/apt.log" \
        MINBIN="$MINBIN" NF_DRM_HEADER="$T/drm/drm.h" NF_FETCH_POLL_SECS=0.05 \
        CURL_FAKE_API_JSON="$CURL_FAKE_API_JSON" CURL_FAKE_TARBALL="$PICKER_TARBALL" \
        CUSTOM_CFG="$KF_HOME/custom.cfg" CFG_TARGET="$KF_HOME/custom.cfg" "$@" "$A"
}

reset_state; with_drm
rm -rf "$KF_HOME"; mkdir -p "$KF_HOME"; cp -r "$UP" "$KF_HOME/nightfall-boot-manager"
# One fetch, checked several ways - not several separate run_kfetch calls: a
# second call would find the just-staged kernel and reuse it rather than
# fetch again, so it would tell us nothing new about the fetch itself.
KF_OUT=$(run_kfetch 2>&1)
says  "fetches the release when no kernel is found locally" "found https://example.invalid" \
      echo "$KF_OUT"
says  "  names the picker asset, not the pixel-slate one alongside it" \
      "9.9.9-picker-installer.tar.gz" echo "$KF_OUT"
holds "  staged where the kernel search already looks" \
      -s "$KF_HOME/nightfall-boot-manager/picker-kernel/vmlinuz"
says  "  and the install ran using it"                "install-nightfall.sh ran" cat "$T/log"

# A real regression this once was: `curl | tail -3` buffered the ENTIRE
# ~80MB download and showed nothing until it finished, indistinguishable from
# a hang - confirmed on real hardware, Bob watching an apply that had in fact
# succeeded. curl now runs in the background with its progress polled
# separately, so this checks that mechanism directly: a stub slow enough for
# the poll loop to catch mid-download, not just that the fetch still works.
reset_state; with_drm
rm -rf "$KF_HOME"; mkdir -p "$KF_HOME"; cp -r "$UP" "$KF_HOME/nightfall-boot-manager"
cat > "$BIN/curl" <<STUB
#!/bin/bash
out=""; args=("\$@")
for i in "\${!args[@]}"; do [ "\${args[\$i]}" = "-o" ] && out="\${args[\$((i+1))]}"; done
if [ -n "\$out" ]; then
    head -c 1000000 "\$CURL_FAKE_TARBALL" > "\$out"
    sleep 0.3
    cat "\$CURL_FAKE_TARBALL" > "\$out"
else
    cat "\${CURL_FAKE_API_JSON:-/nonexistent}"
fi
STUB
chmod +x "$BIN/curl"
SLOW_OUT=$(env HOME="$KF_HOME" PATH="$BIN:$MINBIN" FIXER_SUDO=env FIXER_REPO="$REPO" \
    NF_CLONE_URL="$UP" PROC_CMDLINE=/dev/null LOG="$T/log" APT_LOG="$T/apt.log" \
    MINBIN="$MINBIN" NF_DRM_HEADER="$T/drm/drm.h" NF_FETCH_POLL_SECS=0.1 \
    CURL_FAKE_API_JSON="$CURL_FAKE_API_JSON" CURL_FAKE_TARBALL="$PICKER_TARBALL" \
    CUSTOM_CFG="$KF_HOME/custom.cfg" CFG_TARGET="$KF_HOME/custom.cfg" "$A" 2>&1)
says  "a slow download shows periodic progress, not silence" "downloading," echo "$SLOW_OUT"
says  "  with a byte count that grows"                       "MB so far" echo "$SLOW_OUT"
cat > "$BIN/curl" <<STUB
#!/bin/bash
out=""; args=("\$@")
for i in "\${!args[@]}"; do [ "\${args[\$i]}" = "-o" ] && out="\${args[\$((i+1))]}"; done
for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
if [ -n "\$out" ]; then
    [ -n "\${CURL_FAIL_DOWNLOAD:-}" ] && exit 22
    cp "\${CURL_FAKE_TARBALL:-/nonexistent}" "\$out" 2>/dev/null || exit 22
elif [ "\${url##*/}" = SHA256SUMS ]; then
    cat "\${CURL_FAKE_SUMS:-/nonexistent}" 2>/dev/null || exit 22
else
    [ -n "\${CURL_FAIL_API:-}" ] && exit 22
    cat "\${CURL_FAKE_API_JSON:-/nonexistent}" 2>/dev/null || exit 22
fi
STUB
chmod +x "$BIN/curl"   # restore the normal fast stub for the rest of the suite

reset_state; with_drm
rm -rf "$KF_HOME"; mkdir -p "$KF_HOME"; cp -r "$UP" "$KF_HOME/nightfall-boot-manager"
says  "an explicit FIXER_NIGHTFALL_KERNEL skips the fetch entirely" "picker kernel: $FAKE_KERNEL" \
      run_kfetch FIXER_NIGHTFALL_KERNEL="$FAKE_KERNEL"
lacks "  curl's API was never even asked"             "found https://" \
      run_kfetch FIXER_NIGHTFALL_KERNEL="$FAKE_KERNEL"

reset_state; with_drm
rm -rf "$KF_HOME"; mkdir -p "$KF_HOME"; cp -r "$UP" "$KF_HOME/nightfall-boot-manager"
says  "API unreachable: falls through to the normal 'not found' message" \
      "No picker kernel image found" run_kfetch CURL_FAIL_API=1
holds "  nothing was staged"                          ! -e "$KF_HOME/nightfall-boot-manager/picker-kernel/vmlinuz"

reset_state; with_drm
rm -rf "$KF_HOME"; mkdir -p "$KF_HOME"; cp -r "$UP" "$KF_HOME/nightfall-boot-manager"
says  "download failing: same graceful fallback, not a crash" \
      "No picker kernel image found" run_kfetch CURL_FAIL_DOWNLOAD=1
holds "  nothing was staged"                          ! -e "$KF_HOME/nightfall-boot-manager/picker-kernel/vmlinuz"

reset_state; with_drm
rm -rf "$KF_HOME"; mkdir -p "$KF_HOME"; cp -r "$UP" "$KF_HOME/nightfall-boot-manager"
# ---- the "nightfall" release shape: a BARE vmlinuz-<rel>-nightfall asset next
# to a SHA256SUMS, newest in the feed, ahead of the older picker tarball. It
# must win over the picker one, be verified, and a bad checksum must not stage.
NF_BARE="$T/vmlinuz-9.9.10-BobZKernel-nightfall"; echo "fake nightfall vmlinuz bytes" > "$NF_BARE"
NF_JSON="$T/releases-nightfall.json"
cat > "$NF_JSON" <<JSON
[
  {"tag_name": "v9.9.10-nightfall", "assets": [
    {"browser_download_url": "https://example.invalid/v9.9.10-nightfall/config-9.9.10-BobZKernel-nightfall"},
    {"browser_download_url": "https://example.invalid/v9.9.10-nightfall/SHA256SUMS"},
    {"browser_download_url": "https://example.invalid/v9.9.10-nightfall/vmlinuz-9.9.10-BobZKernel-nightfall"}]},
  {"tag_name": "v9.9.9-picker", "assets": [{"browser_download_url": "https://example.invalid/BobZKernel-9.9.9-picker-installer.tar.gz"}]}
]
JSON
GOOD_SUMS="$T/sums-good"; echo "$(sha256sum "$NF_BARE" | cut -d" " -f1)  vmlinuz-9.9.10-BobZKernel-nightfall" > "$GOOD_SUMS"
BAD_SUMS="$T/sums-bad";  echo "0000000000000000000000000000000000000000000000000000000000000000  vmlinuz-9.9.10-BobZKernel-nightfall" > "$BAD_SUMS"
NF_STAGE="$KF_HOME/nightfall-boot-manager/picker-kernel/vmlinuz"

rm -rf "$KF_HOME"; mkdir -p "$KF_HOME"; cp -r "$UP" "$KF_HOME/nightfall-boot-manager"
NB_OUT=$(run_kfetch CURL_FAKE_API_JSON="$NF_JSON" CURL_FAKE_TARBALL="$NF_BARE" CURL_FAKE_SUMS="$GOOD_SUMS" 2>&1)
says  "nightfall release: the bare vmlinuz is chosen over the picker tarball" \
      "found https://example.invalid/v9.9.10-nightfall/vmlinuz-9.9.10-BobZKernel-nightfall" echo "$NB_OUT"
says  "  checksum verified" "checksum ok" echo "$NB_OUT"
holds "  staged byte-for-byte" -s "$NF_STAGE"
holds "  and its contents are the downloaded file's" "$(cat "$NF_STAGE")" = "$(cat "$NF_BARE")"

rm -rf "$KF_HOME"; mkdir -p "$KF_HOME"; cp -r "$UP" "$KF_HOME/nightfall-boot-manager"
NB_OUT=$(run_kfetch CURL_FAKE_API_JSON="$NF_JSON" CURL_FAKE_TARBALL="$NF_BARE" CURL_FAKE_SUMS="$BAD_SUMS" 2>&1)
says  "nightfall release: a checksum mismatch is refused" "checksum mismatch" echo "$NB_OUT"
holds "  and nothing was staged" ! -e "$NF_STAGE"
says  "  falling through to the clear no-kernel message" "No picker kernel image found" echo "$NB_OUT"

rm -rf "$KF_HOME"; mkdir -p "$KF_HOME"; cp -r "$UP" "$KF_HOME/nightfall-boot-manager"
NB_OUT=$(run_kfetch CURL_FAKE_API_JSON="$NF_JSON" CURL_FAKE_TARBALL="$NF_BARE" CURL_FAKE_SUMS=/nonexistent 2>&1)
says  "nightfall release: no SHA256SUMS available still installs, and says so" "no SHA256SUMS entry" echo "$NB_OUT"
holds "  staged" -s "$NF_STAGE"

# ---- the kernel-only tarball: top-level vmlinuz-<rel> + config, no boot/, no
# installer files. It is preferred over the bare asset, and its checksum (listed
# in the same SHA256SUMS) is enforced like the bare one's.
NFT_SRC="$T/nft_src"; mkdir -p "$NFT_SRC"
cp "$NF_BARE" "$NFT_SRC/vmlinuz-9.9.10-BobZKernel-nightfall"; echo cfg > "$NFT_SRC/config-9.9.10-BobZKernel-nightfall"
NFT_TAR="$T/BobZKernel-9.9.10-nightfall-kernel.tar.gz"
( cd "$NFT_SRC" && tar czf "$NFT_TAR" vmlinuz-9.9.10-BobZKernel-nightfall config-9.9.10-BobZKernel-nightfall )
NFT_JSON="$T/releases-nightfall-tar.json"
cat > "$NFT_JSON" <<JSON
[
  {"tag_name": "v9.9.10-nightfall", "assets": [
    {"browser_download_url": "https://example.invalid/v9.9.10-nightfall/BobZKernel-9.9.10-nightfall-kernel.tar.gz"},
    {"browser_download_url": "https://example.invalid/v9.9.10-nightfall/vmlinuz-9.9.10-BobZKernel-nightfall"},
    {"browser_download_url": "https://example.invalid/v9.9.10-nightfall/SHA256SUMS"}]}
]
JSON
NFT_GOOD="$T/sums-tar-good"; echo "$(sha256sum "$NFT_TAR" | cut -d" " -f1)  BobZKernel-9.9.10-nightfall-kernel.tar.gz" > "$NFT_GOOD"
NFT_BAD="$T/sums-tar-bad";   echo "1111111111111111111111111111111111111111111111111111111111111111  BobZKernel-9.9.10-nightfall-kernel.tar.gz" > "$NFT_BAD"

rm -rf "$KF_HOME"; mkdir -p "$KF_HOME"; cp -r "$UP" "$KF_HOME/nightfall-boot-manager"
NT_OUT=$(run_kfetch CURL_FAKE_API_JSON="$NFT_JSON" CURL_FAKE_TARBALL="$NFT_TAR" CURL_FAKE_SUMS="$NFT_GOOD" 2>&1)
says  "kernel-only tarball is chosen over the bare vmlinuz" "found https://example.invalid/v9.9.10-nightfall/BobZKernel-9.9.10-nightfall-kernel.tar.gz" echo "$NT_OUT"
says  "  checksum verified" "checksum ok" echo "$NT_OUT"
holds "  the vmlinuz member (not config) is what got staged" "$(cat "$NF_STAGE")" = "$(cat "$NF_BARE")"

rm -rf "$KF_HOME"; mkdir -p "$KF_HOME"; cp -r "$UP" "$KF_HOME/nightfall-boot-manager"
NT_OUT=$(run_kfetch CURL_FAKE_API_JSON="$NFT_JSON" CURL_FAKE_TARBALL="$NFT_TAR" CURL_FAKE_SUMS="$NFT_BAD" 2>&1)
says  "kernel-only tarball: a checksum mismatch is refused" "checksum mismatch" echo "$NT_OUT"
holds "  and nothing was staged" ! -e "$NF_STAGE"

CFGONLY="$T/cfgonly.tar.gz"; ( cd "$NFT_SRC" && tar czf "$CFGONLY" config-9.9.10-BobZKernel-nightfall )
rm -rf "$KF_HOME"; mkdir -p "$KF_HOME"; cp -r "$UP" "$KF_HOME/nightfall-boot-manager"
NT_OUT=$(run_kfetch CURL_FAKE_API_JSON="$NFT_JSON" CURL_FAKE_TARBALL="$CFGONLY" CURL_FAKE_SUMS=/nonexistent 2>&1)
says  "kernel-only tarball with no vmlinuz member is refused" "no vmlinuz-" echo "$NT_OUT"
holds "  and nothing was staged" ! -e "$NF_STAGE"

# ---- rollback copy: the installer overwrites /boot/nightfall/{vmlinuz,initramfs.img}
# in place, so a DIFFERENT incoming kernel keeps the pair being replaced as
# *.previous, and an identical one leaves an existing rollback pair alone.
NB="$T/nfboot"
seed_boot() { rm -rf "$NB"; mkdir -p "$NB"; echo OLDK > "$NB/vmlinuz"; echo OLDI > "$NB/initramfs.img"; }
NEWK="$T/newk"; echo NEWK > "$NEWK"
seed_boot
rm -rf "$KF_HOME"; mkdir -p "$KF_HOME"; cp -r "$UP" "$KF_HOME/nightfall-boot-manager"
RB_OUT=$(run_kfetch FIXER_NIGHTFALL_KERNEL="$NEWK" NF_BOOT_DIR="$NB" 2>&1)
says  "a different incoming kernel is announced as kept" "kept the replaced kernel" echo "$RB_OUT"
holds "  old kernel kept as vmlinuz.previous" "$(cat "$NB/vmlinuz.previous" 2>/dev/null)" = OLDK
holds "  old initramfs kept as a matched pair" "$(cat "$NB/initramfs.img.previous" 2>/dev/null)" = OLDI
seed_boot; cp "$NB/vmlinuz" "$T/samek"; echo KEEP > "$NB/vmlinuz.previous"
rm -rf "$KF_HOME"; mkdir -p "$KF_HOME"; cp -r "$UP" "$KF_HOME/nightfall-boot-manager"
run_kfetch FIXER_NIGHTFALL_KERNEL="$T/samek" NF_BOOT_DIR="$NB" >/dev/null 2>&1
holds "  an identical kernel leaves the existing rollback pair alone" "$(cat "$NB/vmlinuz.previous")" = KEEP
seed_boot
rm -rf "$KF_HOME"; mkdir -p "$KF_HOME"; cp -r "$UP" "$KF_HOME/nightfall-boot-manager"
run_kfetch FIXER_NIGHTFALL_KERNEL="$NEWK" NF_BOOT_DIR="$NB/nonexistent" >/dev/null 2>&1
holds "  a fresh install (nothing there yet) makes no rollback files" ! -e "$NB/vmlinuz.previous"

# ---- update mode: the installed kernel is never "found", the release is
# fetched, and a failed fetch stops before touching anything.
rm -rf "$KF_HOME"; mkdir -p "$KF_HOME/nightfall-boot-manager"; cp -r "$UP/." "$KF_HOME/nightfall-boot-manager/"
mkdir -p "$KF_HOME/nightfall-boot-manager/picker-kernel"; echo STALE > "$KF_HOME/nightfall-boot-manager/picker-kernel/vmlinuz"
UP_OUT=$(run_kfetch FIXER_NIGHTFALL_UPDATE=1 CURL_FAKE_API_JSON="$NFT_JSON" CURL_FAKE_TARBALL="$NFT_TAR" CURL_FAKE_SUMS="$NFT_GOOD" 2>&1)
says  "update mode fetches even though a kernel is already on disk" "found https://example.invalid" echo "$UP_OUT"
holds "  and stages the new one over the stale one" "$(cat "$NF_STAGE")" = "$(cat "$NF_BARE")"
rm -rf "$KF_HOME"; mkdir -p "$KF_HOME/nightfall-boot-manager"; cp -r "$UP/." "$KF_HOME/nightfall-boot-manager/"
mkdir -p "$KF_HOME/nightfall-boot-manager/picker-kernel"; echo STALE > "$KF_HOME/nightfall-boot-manager/picker-kernel/vmlinuz"
says  "update mode with no network refuses rather than reinstalling the old kernel" \
      "No picker kernel image found" run_kfetch FIXER_NIGHTFALL_UPDATE=1 CURL_FAIL_API=1

# ---- CPU below x86-64-v2: refused up front, before any network or build work.
rm -rf "$KF_HOME"; mkdir -p "$KF_HOME"; cp -r "$UP" "$KF_HOME/nightfall-boot-manager"
: > "$T/log"
CPU_OUT=$(run_kfetch FIXER_CPUINFO="$CPU_OLD" FIXER_NIGHTFALL_KERNEL="$FAKE_KERNEL" 2>&1); CPU_RC=$?
holds "a CPU below x86-64-v2 makes apply refuse (non-zero)" "$CPU_RC" -ne 0
says  "  naming the missing features"          "sse4_1" echo "$CPU_OUT"
says  "  and that nothing was changed"        "Nothing was changed" echo "$CPU_OUT"
lacks "  and it never reached the install"    "install-nightfall.sh ran" cat "$T/log"
lacks "  or the network"                      "found https://" echo "$CPU_OUT"
CPU_OUT=$(run_kfetch FIXER_CPUINFO="$CPU_OLD" FIXER_BUILD_ONLY=1 2>&1)
lacks "a build check installs no kernel, so it does not care" "x86-64-v2" echo "$CPU_OUT"

rm -rf "$KF_HOME"; mkdir -p "$KF_HOME"; cp -r "$UP" "$KF_HOME/nightfall-boot-manager"
NO_MATCH_JSON="$T/releases-no-picker.json"
echo '[{"tag_name": "v9.9.9-pixel-slate", "assets": [{"browser_download_url": "https://example.invalid/BobZKernel-9.9.9-pixel-slate-installer.tar.gz"}]}]' \
    > "$NO_MATCH_JSON"
says  "a feed with no picker release at all: same graceful fallback" \
      "no nightfall (or older picker) kernel release found" run_kfetch CURL_FAKE_API_JSON="$NO_MATCH_JSON"

reset_state; with_drm
rm -rf "$KF_HOME"; mkdir -p "$KF_HOME"; cp -r "$UP" "$KF_HOME/nightfall-boot-manager"
BAD_TARBALL="$T/not-a-kernel.tar.gz"
( cd "$T" && mkdir -p emptydir && tar czf "$BAD_TARBALL" emptydir )
says  "a release asset with no boot/vmlinuz-* inside: refuses, does not stage garbage" \
      "no vmlinuz-" run_kfetch CURL_FAKE_TARBALL="$BAD_TARBALL"
holds "  nothing was staged"                          ! -e "$KF_HOME/nightfall-boot-manager/picker-kernel/vmlinuz"

reset_state; with_drm
rm -rf "$KF_HOME"; mkdir -p "$KF_HOME"; cp -r "$UP" "$KF_HOME/nightfall-boot-manager"
run_kfetch >/dev/null 2>&1
KF2_HOME="$T/home_kfetch2"; rm -rf "$KF2_HOME"; mkdir -p "$KF2_HOME"
cp -r "$KF_HOME/nightfall-boot-manager" "$KF2_HOME/nightfall-boot-manager"
lacks "a kernel already staged from an earlier fetch is reused, not re-fetched" \
      "no picker kernel found locally" \
      env HOME="$KF2_HOME" PATH="$BIN:$MINBIN" FIXER_SUDO=env FIXER_REPO="$REPO" \
          NF_CLONE_URL="$UP" PROC_CMDLINE=/dev/null LOG="$T/log" APT_LOG="$T/apt.log" \
          MINBIN="$MINBIN" NF_DRM_HEADER="$T/drm/drm.h" CURL_FAIL_API=1 \
          CUSTOM_CFG="$KF2_HOME/custom.cfg" CFG_TARGET="$KF2_HOME/custom.cfg" "$A"

reset_state; with_drm
BO_KF_HOME="$T/home_bo_kf"; mkdir -p "$BO_KF_HOME"; cp -r "$UP" "$BO_KF_HOME/nightfall-boot-manager"
says  "build-only never fetches a kernel - CI should not reach for the network" \
      "not needed for a build check" \
      env FIXER_BUILD_ONLY=1 HOME="$BO_KF_HOME" PATH="$BIN:$MINBIN" FIXER_SUDO=env \
          FIXER_REPO="$REPO" LOG="$T/log" APT_LOG="$T/apt.log" \
          CUSTOM_CFG="$BO_KF_HOME/custom.cfg" CFG_TARGET="$BO_KF_HOME/custom.cfg" "$A"

# ---- build-only: still just reports, never calls apt-get -------------------
# Needs a checkout already in place - a build-only run with none would refuse
# at the earlier "checkout not found" gate before ever reaching this check.
reset_state; with_drm
BO_HOME="$T/home_bo_tools"; mkdir -p "$BO_HOME"; cp -r "$UP" "$BO_HOME/nightfall-boot-manager"
run_bo() {
    env HOME="$BO_HOME" PATH="$BIN:$MINBIN" FIXER_SUDO=env FIXER_REPO="$REPO" \
        NF_CLONE_URL="$UP" PROC_CMDLINE=/dev/null LOG="$T/log" APT_LOG="$T/apt.log" \
        MINBIN="$MINBIN" NF_DRM_HEADER="$T/drm/drm.h" \
        CUSTOM_CFG="$BO_HOME/custom.cfg" CFG_TARGET="$BO_HOME/custom.cfg" \
        FIXER_BUILD_ONLY=1 "$A"
}
rm -f "$MINBIN/kexec"
says  "build-only reports missing tools without installing them" "cannot check" run_bo
lacks "  apt-get was never invoked"                   "apt-get install" cat "$T/apt.log"
ln -sf "$TRUE_REAL" "$MINBIN/kexec"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
