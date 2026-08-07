# Named entity lookup benchmark

The benchmark uses all 2,231 WHATWG entity spellings from
`bench/parsers/lexbor/utils/lexbor/html/data/entities.json`. Every variant is
verified against every name and UTF-8 value before timing starts.

## Variants

- Length-sharded FNV-1a open-address hash table, 5,028 `u16` slots.
- Length-sharded fixed-depth trie, 13,387 nodes.
- Non-sharded fixed-depth trie, 9,854 nodes.

Trie edges are sorted and searched with binary search. Generated static source
is used so the timing excludes table construction and Zig comptime evaluation.

## Commands

```bash
python3 bench/entity_lookup/generate.py
zig build-exe bench/entity_lookup/bench.zig -O ReleaseFast \
  -femit-bin=bench/entity_lookup/entity-bench
./bench/entity_lookup/entity-bench
```

Five runs of five million lookups per workload were collected. Values below
are medians in nanoseconds per lookup.

| Variant | Common hits | Uncommon hits | Prefix-heavy misses | Random misses |
|---|---:|---:|---:|---:|
| Length-sharded hash | 10.459 | 13.320 | 9.674 | 11.846 |
| Length-sharded trie | 15.764 | 36.335 | 38.600 | 7.360 |
| Full trie | 14.180 | 36.917 | 47.186 | 9.660 |

Separate ReleaseFast executables referencing only one lookup implementation
were compared with an equivalent baseline executable. Incremental `.rodata`:

| Variant | Incremental `.rodata` |
|---|---:|
| Length-sharded hash | 22,905 bytes |
| Length-sharded trie | 166,761 bytes |
| Full trie | 131,561 bytes |

The complete single-variant executable sizes reported by `size` were 809,144,
952,504, and 915,640 bytes respectively; the baseline was 784,559 bytes.

## Decision

The length-sharded hash table is selected. It is fastest for both hit classes
and prefix-heavy misses, while adding approximately 22.4 KiB of read-only
data—about one seventh of the sharded trie overhead. The sharded trie wins only
on random misses, which usually reject near the root and are less representative
of entity parsing after an ampersand.
