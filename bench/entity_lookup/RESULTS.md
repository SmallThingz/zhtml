# Named entity lookup benchmark

The benchmark uses all 2,231 WHATWG entity spellings from
`bench/parsers/lexbor/utils/lexbor/html/data/entities.json`. Every variant is
verified against every name and UTF-8 value before timing starts.

## Variants

- Length-sharded and unsharded `std.hash.Wyhash` open-address tables.
- Length-sharded and unsharded runtime `std.StringHashMap` tables.
- An unsharded generated static table using `std.hash_map.StringContext`, the
  top hash byte as metadata, and linear probing (the zdotenv-style std port).

There are no trie implementations or generated trie artifacts.

## Commands

```bash
python3 bench/entity_lookup/generate.py
zig build-exe bench/entity_lookup/bench.zig -O ReleaseFast \
  -femit-bin=/tmp/html-entity-hash-bench
/tmp/html-entity-hash-bench
```

The figures below are a representative ReleaseFast run in nanoseconds per
operation. The end-to-end column performs the decreasing-length search used by
entity decoding.

| Variant | Common hits | Uncommon hits | Prefix misses | Random misses | Longest prefix |
|---|---:|---:|---:|---:|---:|
| Wyhash sharded | 8.801 | 8.140 | 7.935 | 12.146 | 39.961 |
| Wyhash unsharded | 7.415 | 7.290 | 3.997 | 6.419 | 42.854 |
| std runtime sharded | 8.266 | 8.007 | 11.788 | 17.275 | 37.558 |
| std runtime unsharded | 8.104 | 7.677 | 4.366 | 5.652 | 39.518 |
| std static unsharded | 7.510 | 7.266 | 3.782 | 4.493 | 33.557 |

## Decision

The generated static, unsharded std-hash layout is selected. It wins every
direct workload in the representative run and has the best median for the
actual longest-prefix operation. Sharding is therefore not used in production;
the sharded variants remain only in the benchmark for reproducibility.
