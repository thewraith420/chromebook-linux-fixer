#!/bin/bash
# build-selftest.sh — do the from-source fixes still compile?
#
#   build-selftest.sh            every from-source fix
#   build-selftest.sh <id> ...   just these
#
# exit 0 = everything that can build, built.  1 = something failed.
#
# This is not about whether a fix is applied. It is about whether it COULD be,
# from nothing, today. Those are different questions and only the first has
# ever had a check: verify looks at the installed binary and the running
# service, both of which keep saying "applied" long after the source stopped
# compiling. cros-fp-fingerprint was unbuildable for two weeks behind a green
# "applied" (issue #1), and nobody local noticed because nobody rebuilds a fix
# that is already installed.
#
# The reason that matters here rather than only to strangers: restoring from a
# backup IS a clean install. Every from-source fix has to build again on the
# restored system, at the moment things are already going badly. And one of
# them is cros-fp-fingerprint, which is what pkexec authenticates against under
# the GUI - so its build failing costs the escalation path used to apply
# everything else.
#
# These fixes also pin upstream revisions and patch them, so they can rot with
# no local change at all: an upstream repo moving, a yanked crate, a tag
# repointed. The only way to know is to build.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FIXER_REPO="$REPO"
export FIXER_BUILD_ONLY=1

# id : what invoking its real build path looks like. Deliberately the SAME code
# apply runs - a reimplementation here would test this file, not the fix.
buildable() {
    case "$1" in
        cros-fp-fingerprint) echo "apply" ;;
        ipu3-camera)         echo "build.sh ${FIXER_ISP_MODE:-hardware}" ;;
        *)                   return 1 ;;
    esac
}

run_one() {
    local id="$1" how
    how=$(buildable "$id") || { echo "skip  $id (nothing to build)"; return 0; }

    local dir="$REPO/fixes/$id"
    [ -d "$dir" ] || { echo "FAIL  $id (no such fix)"; return 1; }

    echo "----- $id -----"
    local rc=0
    case "$how" in
        apply)
            FIX_DIR="$dir" FIX_ID="$id" "$dir/apply.sh" || rc=$? ;;
        "build.sh "*)
            FIX_DIR="$dir" FIX_ID="$id" "$dir/build.sh" "${how#build.sh }" || rc=$? ;;
    esac
    case "$rc" in
        0) echo "ok    $id"; CHECKED=$((CHECKED + 1)) ;;
        # 2 means the build could not be attempted here - no toolchain, no
        # network - which is not evidence the source is broken. Reported, and
        # not counted as a failure, because a check that cries wolf on a
        # machine missing meson teaches people to ignore it.
        2) echo "SKIP  $id (could not be checked here - see above)"
           SKIPPED=$((SKIPPED + 1)); rc=0 ;;
        *) echo "FAIL  $id (exit $rc)" ;;
    esac
    return "$rc"
}

TARGETS=("$@")
if [ ${#TARGETS[@]} -eq 0 ]; then
    mapfile -t TARGETS < <(for d in "$REPO"/fixes/*/; do
        id=$(basename "$d"); buildable "$id" >/dev/null && echo "$id"; done)
fi

WORST=0; CHECKED=0; SKIPPED=0
for id in "${TARGETS[@]}"; do
    run_one "$id" || WORST=1
done

echo
# Say what was actually verified. "All fixes still build" after building none
# of them is the exact failure this script exists to catch, and the first
# version of this summary printed precisely that on a machine with no Rust
# toolchain - a green result that had checked nothing.
if [ "$WORST" -ne 0 ]; then
    echo "At least one from-source fix no longer builds - a restore would not"
    echo "be able to reinstall it. See the output above."
elif [ "$CHECKED" -eq 0 ]; then
    echo "NOTHING WAS VERIFIED: $SKIPPED fix(es) could not be checked on this"
    echo "machine, and none were built. This is not a pass - install what the"
    echo "messages above ask for, or run this where those tools exist."
    WORST=2
elif [ "$SKIPPED" -gt 0 ]; then
    echo "$CHECKED fix(es) still build. $SKIPPED could not be checked here, so"
    echo "this is a partial answer - those remain unknown, not fine."
else
    echo "All $CHECKED from-source fix(es) still build."
fi
exit "$WORST"
