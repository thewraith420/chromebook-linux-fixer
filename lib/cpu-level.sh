#!/bin/bash
# cpu-level.sh — does this CPU meet x86-64-v2?  Sourced, not run.
#
#   cpu_x86_64_v2_missing [cpuinfo]   prints the missing feature names, one line;
#                                     empty output means v2 is met
#
# The Nightfall kernel is built for the x86-64-v2 baseline (any PC from roughly
# 2009 on: Nehalem / Bulldozer and later, and every Intel/AMD chip a Chromebook
# or a current laptop ships with). A kernel built for a level the CPU lacks
# dies at the first unsupported instruction - before there is a console - so
# this is checked BEFORE anything is installed, not discovered at boot.
#
# v2 = the baseline plus CMPXCHG16B, LAHF/SAHF, POPCNT, SSE3, SSSE3, SSE4.1,
# SSE4.2. The names below are /proc/cpuinfo's spellings, not the ISA's.
#
# $FIXER_CPUINFO overrides the file so tests can exercise a CPU that is not
# the one they run on.

cpu_x86_64_v2_missing() {
    local file="${1:-${FIXER_CPUINFO:-/proc/cpuinfo}}" flags f missing=""
    flags=$(grep -m1 '^flags' "$file" 2>/dev/null | cut -d: -f2)
    [ -n "$flags" ] || { echo "cpu flags unreadable"; return 0; }
    for f in lm cx16 lahf_lm popcnt pni ssse3 sse4_1 sse4_2; do
        case " $flags " in *" $f "*) ;; *) missing="$missing $f" ;; esac
    done
    echo "${missing# }"
}
