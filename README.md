# lifetch

the fastest way to fetch your system info!

```bash
~ ./bench.sh
== wall time ==
Benchmark 1: zig-out/bin/lifetch (5000 runs)
                mean     ±       σ          min     …     max
  Wall Time    244.8 µs  ±   276.5 µs     137.8 µs  …  2609.9 µs
```

bench.sh builds first, then measures wall time pinned to one core with a private
HOME. `./bench.sh --compare-config FILE` A/Bs two configs in one invocation.

~100 KB static binary, 33 syscalls for the default config (6 for a minimal one),
no heap.

same machine (busy i9-14900HX), pinned, both binaries benchmarked in one
invocation:

| what runs | mean | min |
| --- | --- | --- |
| old 3-line default | ≈154 µs | ≈128 µs |
| default: + mem/swap/disk/cpu | ≈246 µs | ≈199 µs |
| default + optional gpus line | ≈268 µs | — |

the new info families cost ~60% startup over the old 3-line default; quieter runs
show the same ratios at lower absolutes. per-family costs are documented in
[config.ini](config.ini) — trim the format to trim the latency.

## what it shows

- `mem` `swap` — used / total (percent); the pieces too: `{mem_used}` `{mem_total}` `{mem_percent}` …
- `disks` — every real disk joined; `{disk}` one disk, picked by mount path, device or index: `{disk(/home)}` `{disk(2)}`
- `cpu` `cpu_cores` `cpu_threads` `cpu_percent` `load`
- `gpus` — every GPU (name, `{gpu_vram}`, `{gpu_percent}`); `{gpu(1)}` picks by index
- `kernel` `pkgs` `uptime` `term` `wm` `session` `distro` `user` `host` `shell`

## tested on

- archlinux
- voidlinux

## config

generated inside your home directory at
`~/.config/lifetch/config`

default config can also be found [here](config.ini)

options come before `format = `: `units`, `precision`, `sep.disk`, `sep.gpu`, and
your own `var.<name>` text / `color.<name>` colors, printed as `{@name}` and
`{color.name}`. lines after `format = ` are literal output — nothing a future
version adds can collide with your layout.

## installing from package managers

AUR:
```bash
paru -S lifetch-git
```

## building from src

## prerequisites

- [zig master](https://ziglang.org/) or later

## building

```bash
zig build --release=fast
```

## running

```bash
zig build run --release=fast
```
