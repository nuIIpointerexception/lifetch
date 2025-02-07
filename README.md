# lifetch
the fastest way to fetch your system info!

sub 1ms execution time!

```bash
hyperfine --warmup 10 --runs 1000 './lifetch'
Benchmark 1: ./lifetch
  Time (mean ± σ):     919.1 µs ± 638.6 µs    [User: 141.0 µs, System: 1166.9 µs]
  Range (min … max):     0.0 µs … 1999.5 µs    100 runs
```
