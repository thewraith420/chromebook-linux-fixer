#!/bin/bash
# lib/updates.sh against fixture git remotes, a file:// release feed and a
# stub `file`. No network, no real /boot, no privilege.
#
# What matters here is the refusals: a pull that would merge, clobber local
# changes or hide unpushed commits must say why and change nothing - both
# machines commit to these repos, and "update" silently rewriting someone's
# work is worse than not updating at all.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
U="$REPO/lib/updates.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
GIT="git -c user.email=t@t -c user.name=t -c init.defaultBranch=main -c protocol.file.allow=always"

expect() { local name="$1" want="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?
    if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL  $name  (want $want, got $got)"; fi; }
says()   { local name="$1" pat="$2"; shift 2; local out; out=$("$@" 2>&1)
    if grep -q -- "$pat" <<<"$out"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL  $name  (no '$pat' in: $(head -c 300 <<<"$out"))"; fi; }
lacks()  { local name="$1" pat="$2"; shift 2; local out; out=$("$@" 2>&1)
    if grep -q -- "$pat" <<<"$out"; then fail=$((fail+1)); echo "FAIL  $name  (unexpected '$pat')"; else pass=$((pass+1)); fi; }
holds()  { local name="$1"; shift; if [ "$@" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL  $name"; fi; }

# ---- a remote and a checkout of it, standing in for the fixer -----------
ORIGIN="$T/origin.git"; $GIT init -q --bare "$ORIGIN"
FX="$T/fixer"; $GIT clone -q "$ORIGIN" "$FX" 2>/dev/null
cat > "$FX/install.sh" <<'SH'
#!/bin/bash
echo ran >> "$(dirname "$0")/install.ran"
SH
chmod +x "$FX/install.sh"; echo v1 > "$FX/f.txt"
$GIT -C "$FX" add -A; $GIT -C "$FX" commit -q -m one; $GIT -C "$FX" push -q origin HEAD:main 2>/dev/null
$GIT -C "$FX" branch -q --set-upstream-to=origin/main 2>/dev/null || $GIT -C "$FX" branch -q -u origin/main
rm -f "$FX/install.ran"

OTHER="$T/other"; $GIT clone -q "$ORIGIN" "$OTHER" 2>/dev/null
upstream_commit() { echo "$1" > "$OTHER/f.txt"; $GIT -C "$OTHER" commit -qam "$1"; $GIT -C "$OTHER" push -q origin HEAD:main 2>/dev/null; }

NO_NF="$T/no-home"; mkdir -p "$NO_NF"
run() { env HOME="$NO_NF" FIXER_ROOT="$FX" NF_BOOT_DIR="$T/absent" NF_KERNEL_API="file://$T/none" \
        UPDATES_NET_SECS=10 "$U" "$@"; }

# ---- fixer: current -> behind -> pulled ---------------------------------
says  "up to date is reported as such"           "Chromebook Fixer .*up to date" run check fixer
row=$(run check --porcelain fixer 2>&1)
holds "  porcelain state is 'current'" "$(cut -f2 <<<"$row")" = current

upstream_commit v2
row=$(run check --porcelain fixer 2>&1)
holds "a new upstream commit shows as behind"       "$(cut -f2 <<<"$row")" = behind
holds "  and names both revisions"                  -n "$(cut -f3 <<<"$row")" -a -n "$(cut -f4 <<<"$row")"
says  "  human output says UPDATE AVAILABLE"        "UPDATE AVAILABLE" run check fixer
holds "  a check changed nothing on disk"           "$(cat "$FX/f.txt")" = v1

PULL_OUT=$(run pull fixer 2>&1)
says  "pull fast-forwards"                          "updated to" echo "$PULL_OUT"
holds "  the working tree really moved"             "$(cat "$FX/f.txt")" = v2
holds "  install.sh was re-run (launcher refresh)"  -f "$FX/install.ran"
says  "  and it says to restart the app"            "Restart the app" echo "$PULL_OUT"
rm -f "$FX/install.ran"
NOOP_OUT=$(run pull fixer 2>&1)
says  "pulling when already current says so"        "already up to date" echo "$NOOP_OUT"
lacks "  and does not ask for a restart"            "Restart the app" echo "$NOOP_OUT"
holds "  and does not re-run install.sh"            ! -f "$FX/install.ran"

# ---- refusals: each rule has a case where it alone refuses --------------
upstream_commit v3
echo dirty >> "$FX/f.txt"
row=$(run check --porcelain fixer 2>&1)
holds "local changes + behind = blocked"            "$(cut -f2 <<<"$row")" = blocked
expect "  pull refuses (non-zero)"                  1 run pull fixer
holds "  and leaves the local edit exactly as it was" "$(tail -1 "$FX/f.txt")" = dirty
$GIT -C "$FX" checkout -q -- f.txt
holds "  (restored)"                                "$(cat "$FX/f.txt")" = v2

echo mine > "$FX/g.txt"; $GIT -C "$FX" add g.txt; $GIT -C "$FX" commit -qm local
row=$(run check --porcelain fixer 2>&1)
holds "an unpushed local commit + behind = blocked" "$(cut -f2 <<<"$row")" = blocked
says  "  and the reason names the unpushed commit"  "not pushed" run pull fixer
holds "  HEAD did not move"                         "$($GIT -C "$FX" log --oneline | wc -l)" = 3
$GIT -C "$FX" reset -q --hard origin/main; $GIT -C "$FX" branch -q -u origin/main

# only ahead (nothing new upstream) is fine, and is not "behind"
$GIT -C "$FX" pull -q --ff-only 2>/dev/null
echo mine > "$FX/g.txt"; $GIT -C "$FX" add g.txt; $GIT -C "$FX" commit -qm local2
row=$(run check --porcelain fixer 2>&1)
holds "ahead but not behind is current"             "$(cut -f2 <<<"$row")" = current
$GIT -C "$FX" reset -q --hard origin/main

# ---- offline is 'unknown', never an error -------------------------------
mv "$ORIGIN" "$T/origin.gone"
row=$(run check --porcelain fixer 2>&1)
holds "an unreachable remote is 'unknown'"          "$(cut -f2 <<<"$row")" = unknown
expect "  and check itself still exits 0"           0 run check fixer
expect "  pull refuses rather than guessing"        1 run pull fixer
mv "$T/origin.gone" "$ORIGIN"

# ---- the nightfall source checkout --------------------------------------
row=$(run check --porcelain nightfall-source 2>&1)
holds "no nightfall checkout is 'na', not an error" "$(cut -f2 <<<"$row")" = na
expect "  pull says so and fails"                   1 run pull nightfall-source
NF_HOME="$T/nfhome"; mkdir -p "$NF_HOME"; $GIT clone -q "$ORIGIN" "$NF_HOME/nightfall-boot-manager" 2>/dev/null
upstream_commit v4
row=$(env HOME="$NF_HOME" FIXER_ROOT="$FX" NF_BOOT_DIR="$T/absent" NF_KERNEL_API="file://$T/none" "$U" check --porcelain nightfall-source 2>&1)
holds "a found checkout that is behind is reported" "$(cut -f2 <<<"$row")" = behind
env HOME="$NF_HOME" FIXER_ROOT="$FX" "$U" pull nightfall-source >/dev/null 2>&1
holds "  and pull moves it"                         "$(cat "$NF_HOME/nightfall-boot-manager/f.txt")" = v4

# ---- the kernel comparison ----------------------------------------------
STUB="$T/stub"; mkdir -p "$STUB" "$T/boot"
echo bytes > "$T/boot/vmlinuz"
mkfile() { cat > "$STUB/file" <<SH
#!/bin/bash
echo "Linux kernel x86 boot executable bzImage, version $1 (bob@host) #1 SMP, RO-rootFS, swap_dev 0X8, Normal VGA"
SH
chmod +x "$STUB/file"; }
FEED="$T/feed.json"
cat > "$FEED" <<'JSON'
[{"tag_name": "v7.2.7-nightfall", "assets": [
  {"browser_download_url": "https://example.invalid/v7.2.7-nightfall/BobZKernel-7.2.7-nightfall-kernel.tar.gz"},
  {"browser_download_url": "https://example.invalid/v7.2.7-nightfall/vmlinuz-7.2.7-BobZKernel-nightfall"}]},
 {"tag_name": "v7.2.6-pixel-slate", "assets": [{"browser_download_url": "https://example.invalid/vmlinuz-7.2.6-BobZKernel-pixel-slate"}]}]
JSON
krun() { env HOME="$NO_NF" FIXER_ROOT="$FX" NF_BOOT_DIR="$T/boot" NF_KERNEL_API="file://$FEED" PATH="$STUB:$PATH" "$U" "$@"; }

mkfile 7.2.7-BobZKernel-nightfall
row=$(krun check --porcelain nightfall-kernel 2>&1)
holds "same release installed: current"             "$(cut -f2 <<<"$row")" = current
mkfile 7.2.5-BobZKernel-nightfall
row=$(krun check --porcelain nightfall-kernel 2>&1)
holds "older installed: behind"                     "$(cut -f2 <<<"$row")" = behind
holds "  with both versions named"                  "$(cut -f3,4 <<<"$row")" = "$(printf '7.2.5-BobZKernel-nightfall\t7.2.7-BobZKernel-nightfall')"
mkfile 7.2.10-BobZKernel-nightfall
row=$(krun check --porcelain nightfall-kernel 2>&1)
holds "version order, not string order (7.2.10 > 7.2.7)" "$(cut -f2 <<<"$row")" = current
says  "  newer-than-release is said, not hidden"    "newer than the published" krun check nightfall-kernel
mkfile 7.2.5-BobZKernel-nightfall
holds "the pixel-slate release in the feed is not mistaken for it" \
      "$(cut -f4 <<<"$(krun check --porcelain nightfall-kernel 2>&1)")" = 7.2.7-BobZKernel-nightfall

row=$(env HOME="$NO_NF" FIXER_ROOT="$FX" NF_BOOT_DIR="$T/absent" NF_KERNEL_API="file://$FEED" PATH="$STUB:$PATH" "$U" check --porcelain nightfall-kernel 2>&1)
holds "Nightfall not installed: na"                 "$(cut -f2 <<<"$row")" = na
row=$(env HOME="$NO_NF" FIXER_ROOT="$FX" NF_BOOT_DIR="$T/boot" NF_KERNEL_API="file://$T/nofeed" PATH="$STUB:$PATH" "$U" check --porcelain nightfall-kernel 2>&1)
holds "feed unreachable: unknown, not an error"     "$(cut -f2 <<<"$row")" = unknown
rm -f "$STUB/file"; printf '#!/bin/bash\nexit 1\n' > "$STUB/file"; chmod +x "$STUB/file"
row=$(krun check --porcelain nightfall-kernel 2>&1)
holds "unreadable installed version: unknown"       "$(cut -f2 <<<"$row")" = unknown

expect "an unknown component is refused"            1 run check nonsense
expect "pull with no target prints usage and fails" 1 run pull

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
