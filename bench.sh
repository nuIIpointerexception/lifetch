#!/usr/bin/env bash
# Benchmark harness for lifetch. Run from the repository root.
set -euo pipefail

cd "$(dirname "$0")"
BIN=zig-out/bin/lifetch

usage() {
    cat <<'EOF'
usage: bench.sh [--no-build] [--quick] [--save FILE] [--compare FILE]

  --no-build      skip the zig build step
  --quick         smaller benchmark iteration (warmup 50 / runs 500)
  --save FILE     also write the full report to FILE
  --compare FILE  after running, diff -u FILE against this run's report
EOF
}

no_build=0
quick=0
save_file=""
compare_file=""

while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) no_build=1 ;;
        --quick) quick=1 ;;
        --save) save_file="${2:?--save requires a file}"; shift ;;
        --compare) compare_file="${2:?--compare requires a file}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

report="$(mktemp)"
strace_out="$(mktemp)"
perf_out="$(mktemp)"
trap 'rm -f "$report" "$strace_out" "$perf_out"' EXIT

# All report text streams to stdout and is recorded for --save/--compare.
emit() { printf '%s\n' "$@" | tee -a "$report"; }

if [ "$no_build" -eq 0 ]; then
    emit "== build =="
    zig build -Doptimize=ReleaseFast 2>&1 | tee -a "$report"
fi

emit "== binary size =="
emit "$(stat -c%s "$BIN") bytes"

warmup=500
runs=5000
if [ "$quick" -eq 1 ]; then
    warmup=50
    runs=500
fi

emit ""
emit "== wall time =="
if command -v hyperfine >/dev/null 2>&1; then
    # hyperfine discards the benchmarked program's stdout by default.
    hyperfine -N --warmup "$warmup" --runs "$runs" "$BIN" 2>&1 | tee -a "$report"
else
    emit "skipped: hyperfine not installed"
fi

emit ""
emit "== syscall profile =="
if command -v strace >/dev/null 2>&1; then
    strace -c -o "$strace_out" "$BIN" >/dev/null
    tee -a "$report" < "$strace_out"
else
    emit "skipped: strace not installed"
fi

emit ""
emit "== hardware counters =="
if command -v perf >/dev/null 2>&1; then
    # perf writes its summary to stderr; program stdout is discarded.
    perf stat -e task-clock,cycles,instructions,branches,branch-misses,page-faults,context-switches \
        -r 5 "$BIN" >/dev/null 2>"$perf_out" || true
    tee -a "$report" < "$perf_out"
else
    emit "skipped: perf not installed"
fi

if [ -n "$save_file" ]; then
    cp "$report" "$save_file"
fi

if [ -n "$compare_file" ]; then
    printf '\n== comparison vs %s ==\n' "$compare_file"
    diff -u "$compare_file" "$report" || true
fi
