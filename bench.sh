#!/usr/bin/env bash
# Benchmark harness for lifetch. Run from the repository root.
set -euo pipefail

cd "$(dirname "$0")"
BIN=zig-out/bin/lifetch

usage() {
    cat <<'EOF'
usage: bench.sh [--no-build] [--quick] [--save FILE] [--compare FILE]
                [--config FILE] [--compare-config FILE] [--pin N] [--no-pin]

  --no-build            skip the zig build step
  --quick               smaller benchmark iteration (warmup 50 / runs 500)
  --save FILE           also write the full report to FILE
  --compare FILE        after running, diff -u FILE against this run's report
  --config FILE         config installed as the benchmark config (default: config.ini)
  --compare-config FILE A/B this config against --config in one hyperfine run
  --pin N               pin timed runs to CPU N via taskset (default: 0)
  --no-pin              disable CPU pinning
EOF
}

no_build=0
quick=0
save_file=""
compare_file=""
config_file="config.ini"
compare_config=""
pin_cpu=0
pinning=1

while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) no_build=1 ;;
        --quick) quick=1 ;;
        --save) save_file="${2:?--save requires a file}"; shift ;;
        --compare) compare_file="${2:?--compare requires a file}"; shift ;;
        --config) config_file="${2:?--config requires a file}"; shift ;;
        --compare-config) compare_config="${2:?--compare-config requires a file}"; shift ;;
        --pin) pin_cpu="${2:?--pin requires a CPU index}"; shift ;;
        --no-pin) pinning=0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

tmpdir="$(mktemp -d)"
report="$tmpdir/report"
strace_out="$tmpdir/strace.out"
perf_out="$tmpdir/perf.out"
trap 'rm -rf "$tmpdir"' EXIT

# Private benchmark HOME. Results must not depend on the caller's own
# ~/.config/lifetch, and the harness must never write into the real $HOME
# (the binary creates $HOME/.config/lifetch/config when it is missing).
bench_home="$tmpdir/home"
bench_config="$bench_home/.config/lifetch/config"
mkdir -p "$(dirname "$bench_config")"

# CPU pinning. On hybrid P/E-core machines unpinned timings drift ~2x between
# sessions.
#
# BENCHMARK TRAP: never wrap the measured command in `env HOME=...` (or
# `taskset -c N $BIN`) — spawning those helper binaries inside the timed region
# adds their own dynamic-loading cost (~222us for `env` alone), which is the
# same order as the thing being measured. Instead:
#   * export HOME before invoking hyperfine: hyperfine spawns the command with
#     the current environment, so the binary picks up the private HOME for free;
#   * wrap the *outer* tool (hyperfine, strace, perf) in taskset: its children
#     inherit the CPU affinity, so the measured binary is pinned with no extra
#     exec inside the timed path.
pin_wrap=()
pin_desc="disabled (--no-pin)"
if [ "$pinning" -eq 1 ]; then
    if command -v taskset >/dev/null 2>&1; then
        pin_wrap=(taskset -c "$pin_cpu")
        pin_desc="taskset -c $pin_cpu"
    else
        pin_desc="disabled (taskset not installed)"
    fi
fi

# All report text streams to stdout and is recorded for --save/--compare.
emit() { printf '%s\n' "$@" | tee -a "$report"; }

# Install a config file as the benchmark config the binary reads.
install_config() { cp "$1" "$bench_config"; }

emit "== benchmark environment =="
emit "benchmark HOME: $bench_home (private; the real \$HOME is never read or written)"
emit "config: $config_file"
if [ -n "$compare_config" ]; then
    emit "compare config: $compare_config (A/B in one hyperfine run)"
fi
emit "pin: $pin_desc"

if [ "$no_build" -eq 0 ]; then
    emit ""
    emit "== build =="
    zig build -Doptimize=ReleaseFast 2>&1 | tee -a "$report"
fi

emit ""
emit "== binary size =="
emit "$(stat -c%s "$BIN") bytes"

warmup=500
runs=5000
if [ "$quick" -eq 1 ]; then
    warmup=50
    runs=500
fi

# Point HOME at the private tree for every timed run; see the trap above for
# why this must be an export and not `env HOME=...` around the command.
export HOME="$bench_home"

emit ""
emit "== wall time =="
if command -v hyperfine >/dev/null 2>&1; then
    # hyperfine discards the benchmarked program's stdout by default.
    if [ -n "$compare_config" ]; then
        # A/B both configs in ONE hyperfine invocation so they share the same
        # session noise. --prepare installs the right config before each timing
        # run — the swap must not happen inside the timed command, which stays
        # a bare $BIN. The two benchmarks are labelled via --command-name.
        mkdir -p "$tmpdir/cfgs"
        cp "$config_file" "$tmpdir/cfgs/a"
        cp "$compare_config" "$tmpdir/cfgs/b"
        emit "a = $config_file"
        emit "b = $compare_config"
        "${pin_wrap[@]}" hyperfine -N --warmup "$warmup" --runs "$runs" \
            -L cfg a,b \
            --prepare "cp $tmpdir/cfgs/{cfg} $bench_config" \
            --command-name 'config-{cfg}' \
            "$BIN" 2>&1 | tee -a "$report"
    else
        install_config "$config_file"
        "${pin_wrap[@]}" hyperfine -N --warmup "$warmup" --runs "$runs" "$BIN" 2>&1 | tee -a "$report"
    fi
else
    emit "skipped: hyperfine not installed"
fi

emit ""
emit "== syscall profile =="
if command -v strace >/dev/null 2>&1; then
    install_config "$config_file"
    "${pin_wrap[@]}" strace -c -o "$strace_out" "$BIN" >/dev/null
    tee -a "$report" < "$strace_out"
else
    emit "skipped: strace not installed"
fi

emit ""
emit "== hardware counters =="
if command -v perf >/dev/null 2>&1; then
    install_config "$config_file"
    # perf writes its summary to stderr; program stdout is discarded.
    "${pin_wrap[@]}" perf stat -e task-clock,cycles,instructions,branches,branch-misses,page-faults,context-switches \
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
