# lifetch

the fastest way to fetch your system info!

```bash
 ~ zig build --release=fast && hyperfine -N --warmup 500 --runs 5000 'zig-out/bin/lifetch'
Benchmark 1: zig-out/bin/lifetch (5000 runs)
  Wall Time    100.2 µs  ±    10.4 µs      83.1 µs  …   402.4 µs
```

40 KB static binary, about 20 syscalls, no heap.

## tested on

- archlinux
- voidlinux

## config

generated inside your home directory at
`~/.config/lifetch/config`

default config can also be found [here](config.ini)

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
