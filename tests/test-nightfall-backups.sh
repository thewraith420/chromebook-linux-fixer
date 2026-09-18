#!/bin/bash
# lib/nightfall-backups.sh against a fake backup drive. It deletes archives
# people cannot easily recreate, so what it REFUSES matters as much as what it
# does: a path component in a name, a backup that is not there, a drive that
# mounted read-only. Fixtures only - no real drive, no privilege, runs anywhere.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BK="${BK:-$REPO/lib/nightfall-backups.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
export FIXER_SUDO=env          # the fixtures are ours; never escalate in a test

expect() {  # expect <name> <exit> <command...>
    local name="$1" want="$2"; shift 2
    "$@" >/dev/null 2>&1; local got=$?
    if [ "$got" = "$want" ]; then pass=$((pass + 1))
    else fail=$((fail + 1)); echo "FAIL  $name  (want $want, got $got)"; fi
}
says() {    # says <name> <pattern> <command...>
    local name="$1" pat="$2"; shift 2
    local out; out=$("$@" 2>&1)
    if grep -q -- "$pat" <<< "$out"; then pass=$((pass + 1))
    else fail=$((fail + 1)); echo "FAIL  $name  (no '$pat' in output)"; fi
}
lacks() {   # lacks <name> <pattern> <command...>
    local name="$1" pat="$2"; shift 2
    local out; out=$("$@" 2>&1)
    if grep -q -- "$pat" <<< "$out"; then
        fail=$((fail + 1)); echo "FAIL  $name  ('$pat' should not appear)"
    else pass=$((pass + 1)); fi
}
holds() {   # holds <name> <test args...>
    local name="$1"; shift
    if [ "$@" ]; then pass=$((pass + 1))
    else fail=$((fail + 1)); echo "FAIL  $name"; fi
}

DIR="$T/drive/nocturne-backups"
backup() {  # backup <name> <bytes>
    mkdir -p "$DIR"
    head -c "$2" /dev/zero > "$DIR/$1.tar"
    printf 'created:  Mon Sep 15 21:10:03 2026\nsource:   /dev/sda1 <- backup of the system on this machine\nkernel:   7.2.3-BobZKernel-pixel-slate\narchive:  nocturne-backups/%s.tar\nsize_kb:  4096\nkernels:\n  - 7.2.3-BobZKernel-pixel-slate\n' "$1" > "$DIR/$1.info"
}
run() { NF_BACKUP_DIRS="$DIR" "$BK" "$@"; }

backup before-update 4096
backup after-update 8192
head -c 2048 /dev/zero > "$DIR/died-mid-run.tar"     # power loss: no sidecar
printf 'created:  whenever\n' > "$DIR/ghost.info"     # sidecar, no archive

# ---- the view --------------------------------------------------------------
says  "lists a complete backup"            "before-update"    run list
says  "shows when it was taken"            "Mon Sep 15"       run list
says  "shows the kernel it holds"          "7.2.3-BobZKernel" run list
says  "shows free space on the drive"      "free of"          run list
# An unfinished archive is usually the biggest thing on a full drive, and
# Nightfall's own list hides it - so it is shown here, marked, to be deleted.
says  "marks an unfinished archive"        "UNFINISHED"       run list
says  "names the unfinished archive"       "died-mid-run"     run list
# A sidecar with no archive is a few hundred bytes and nothing to restore.
lacks "ignores a stray sidecar"            "ghost"            run list
holds "tab output is one line each"        "$(run list --tab | wc -l)" = 3
says  "tab output carries byte size"       "	8192	"        run list --tab
says  "tab output states completeness"     "	incomplete$"    run list --tab
says  "tab output marks the good one"      "	ok$"            run list --tab

# ---- delete ----------------------------------------------------------------
expect "refuses a path component"          1 run delete "$DIR" ../../etc/passwd
expect "refuses . and .."                  1 run delete "$DIR" ..
expect "refuses a backup that is not there" 1 run delete "$DIR" no-such
expect "refuses a directory that is not there" 1 run delete "$T/nope" after-update
holds  "  nothing was touched"             -f "$DIR/after-update.tar"

expect "deletes a complete backup"         0 run delete "$DIR" before-update
holds  "  the archive is gone"             ! -e "$DIR/before-update.tar"
holds  "  its sidecar went with it"        ! -e "$DIR/before-update.info"
holds  "  the other backup survived"       -f "$DIR/after-update.tar"
holds  "  and kept its sidecar"            -f "$DIR/after-update.info"

expect "deletes an unfinished archive"     0 run delete "$DIR" died-mid-run
holds  "  it is gone"                      ! -e "$DIR/died-mid-run.tar"
says   "  and says it was unfinished"      "unfinished" \
       bash -c 'head -c 512 /dev/zero > "'"$DIR"'/half.tar"; "'"$BK"'" delete "'"$DIR"'" half'

# ---- a drive that mounted read-only must change nothing --------------------
RO="$T/readonly/nocturne-backups"; mkdir -p "$RO"
head -c 1024 /dev/zero > "$RO/locked.tar"; printf 'created:  x\n' > "$RO/locked.info"
chmod -w "$RO"
if [ ! -w "$RO" ]; then      # as root -w is meaningless, so skip rather than lie
    expect "refuses a read-only drive"     1 "$BK" delete "$RO" locked
    holds  "  the archive is still there"  -f "$RO/locked.tar"
    says   "  and says nothing was deleted" "Nothing was deleted" "$BK" delete "$RO" locked
fi
chmod +w "$RO"

# ---- nothing plugged in ----------------------------------------------------
says "explains where backups live"         "nocturne-backups" \
     env NF_BACKUP_DIRS="$T/nothing-here" "$BK" list

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
