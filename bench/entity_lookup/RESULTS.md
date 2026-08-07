# Named entity lookup benchmark

The benchmark uses all 2,231 WHATWG entity spellings from
`bench/parsers/lexbor/utils/lexbor/html/data/entities.json`. Every variant is
verified against every name and UTF-8 value before timing starts.

## Variants

- Length-sharded and unsharded `std.hash.Wyhash` open-address tables.
- Length-sharded and unsharded runtime `std.StringHashMap` tables.
- An unsharded generated static table using `std.hash_map.StringContext`, the
  top hash byte as metadata, and linear probing (the zdotenv-style std port).
- A GNU gperf perfect hash translated to Zig and reproducibly hand-tuned by the
  generator.

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
| Wyhash sharded | 9.070 | 8.101 | 7.979 | 12.095 | 40.123 |
| Wyhash unsharded | 7.631 | 7.227 | 4.092 | 6.402 | 42.209 |
| std runtime sharded | 8.423 | 8.234 | 12.601 | 16.310 | 37.669 |
| std runtime unsharded | 7.981 | 7.576 | 4.199 | 5.497 | 40.094 |
| std static unsharded | 7.647 | 7.368 | 3.828 | 4.333 | 33.153 |
| GNU gperf | 4.487 | 5.055 | 4.999 | 3.157 | 23.653 |

## Decision

Production uses the GNU gperf table generated as ANSI C and translated with
`zig translate-c`, as selected for the library. The generated gperf source, C,
translated Zig, and UTF-8 value wrapper live under
`bench/entity_lookup/generated/`.
The older hash variants remain only as benchmark baselines.
